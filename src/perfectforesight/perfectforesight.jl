using NLsolve

include("makeA.jl")

"""
PerfectForesightSetupOptions type 
    periods::Int64 - number of periods in the simulation [required]
    datafile::String - optional data filename with guess values for the simulation
                       and initial and terminal values
"""
struct PerfectForesightSetupOptions
    periods::Int64
    datafile::String
    function PerfectForesightSetupOptions(options::Dict{String, Any})
        periods = 0
        datafile = ""
        for (k, v) in pairs(options)
            if k == "periods"
                periods = v::Int64
            elseif k == "datafile"
                datafile = v::String
            end
        end
        if periods == 0
            throw(DomainError(periods, "periods must be set to a number greater than zero"))
        end
        new(periods, datafile)
    end 
end
             
    
function perfect_foresight_setup!(context, field)
    options = PerfectForesightSetupOptions(get(field, "options", Dict{String,Any}()))
    context.work.perfect_foresight_setup["periods"] = options.periods
    context.work.perfect_foresight_setup["datafile"] = options.datafile
end

@enum PerfectForesightAlgo trustregionA
@enum LinearSolveAlgo ilu pardiso

struct PerfectForesightSolverOptions
    algo::PerfectForesightAlgo
    display::Bool
    homotopy::Bool
    linear_solve_algo::LinearSolveAlgo
    maxit::Int64
    tolf::Float64
    tolx::Float64
    function PerfectForesightSolverOptions(context, field)
        algo = trustregionA
        display = true
        homotopy = false
        linear_solve_algo = ILU
        maxit = 50
        tolf = 1e-5
        tolx = 1e-5
        for (k, v) in pairs(options)
            if k == "stack_solve_algo"
                algo = v::Int64
            elseif k == "noprint"
                display = false
            elseif k == "print"
                display = true
            elseif k == "homotopy"
                homotopy = true
            elseif k == "no_homotopy"
                homotopy = false
            elseif k == "solve_algo"
                linear_solve_algo = v
            elseif k == "maxit"
                maxit = v
            elseif k == "tolf"
                tolf = v
            elseif k == "tolx"
                tolf = v
            end
        end
        new(algo, display, homotopy,  linear_solve_algo, maxit, tolf, tolx)
    end
end

struct PerfectForesightWs
    y::Vector{Float64}
    x::Matrix{Float64}
    shocks::Matrix{Float64}
    J::Jacobian
    function PerfectForesightWs(context, periods)
        m = context.models[1]
        y = Vector{Float64}(undef, (periods+2)*m.endogenous_nbr)
        exogenous_steady_state = context.results.model_results[1].trends.exogenous_steady_state
        x = repeat(transpose(exogenous_steady_state), periods+1, 1)
        shocks_tmp = context.work.shocks
        pmax = Int64(length(shocks_tmp)/m.exogenous_nbr)
        shocks = Matrix{Float64}(undef, pmax, m.exogenous_nbr)
        shocks .= reshape(shocks_tmp, (pmax, m.exogenous_nbr))
        # adding shocks to exogenous variables
        view(x, 2:pmax+1,:) .+= shocks
        J = Jacobian(context, periods)
        new(y, x, shocks, J)
    end
end

function perfect_foresight_solver!(context, field)
    periods = context.work.perfect_foresight_setup["periods"]
    datafile = context.work.perfect_foresight_setup["datafile"]
    m = context.models[1]
    ncol = m.n_bkwrd + m.n_current + m.n_fwrd + 2 * m.n_both
    tmp_nbr = m.dynamic!.tmp_nbr::Vector{Int64}
    dynamic_ws = DynamicWs(m.endogenous_nbr, m.exogenous_nbr, ncol, sum(tmp_nbr[1:2]))
    perfect_foresight_ws = PerfectForesightWs(context, periods)
    X = perfect_foresight_ws.shocks
    linear_simulation = perfect_foresight_initialization!(context, periods, datafile, X, perfect_foresight_ws, dynamic_ws)
    perfectforesight_core!(perfect_foresight_ws, context, periods, linear_simulation, dynamic_ws)
end

function perfect_foresight_initialization!(context, periods, datafile, exogenous, perfect_foresight_ws, dynamic_ws::DynamicWs)
    linear_simulation = simul_first_order!(context, periods, exogenous, dynamic_ws)
    return linear_simulation
end

function simul_first_order!(context::Context, periods::Int64, X::AbstractMatrix{Float64}, dynamic_ws::DynamicWs)
    pre_options = Dict{String, Any}("periods" => periods)
    options = StochSimulOptions(pre_options)
    m = context.models[1]
    results = context.results.model_results[1]
    params = context.work.params
    compute_stoch_simul!(context, dynamic_ws, params, options)
    steadystate = results.trends.endogenous_steady_state
    linear_trend = results.trends.endogenous_linear_trend
    y0 = zeros(m.endogenous_nbr)
    simulresults = Matrix{Float64}(undef, m.endogenous_nbr, periods)
    work = context.work
    histval = work.histval
    modfileinfo = context.modfileinfo
    if modfileinfo["has_histval"]
        for i in eachindex(skipmissing(view(work.histval, size(work.histval, 1), :)))
            y0[i] = work.histval[end, i]
        end
    else
        if work.model_has_trend[1]
            y0 .= steadystate - linear_trend
        else
            y0 .= steadystate
        end
    end
    A = zeros(m.endogenous_nbr, m.endogenous_nbr)
    B = zeros(m.endogenous_nbr, m.exogenous_nbr)
    make_A_B!(A, B, m, results)
    simul_first_order!(simulresults, y0, steadystate, A, B, X)
    return simulresults
end


function perfectforesight_core!(perfect_foresight_ws::PerfectForesightWs,
                                context::Context,
                                periods::Int64,
                                y0::Matrix{Float64},
                                dynamic_ws::DynamicWs)
    m = context.models[1]
    results = context.results.model_results[1]
    work = context.work
    residuals = zeros(periods*m.endogenous_nbr)
    dynamic_variables = dynamic_ws.dynamic_variables
    temp_vec = dynamic_ws.temporary_values
    steadystate = results.trends.endogenous_steady_state
    initialvalues = steadystate
    terminalvalues = view(y0, :, periods)
    params = work.params
    JJ = perfect_foresight_ws.J
    
    exogenous = perfect_foresight_ws.x

    ws_threaded = [Dynare.DynamicWs(m.endogenous_nbr,
                                    m.exogenous_nbr,
                                    length(dynamic_variables),
                                    length(temp_vec))
                   for i = 1:Threads.nthreads()]

    f!(residuals, y) = get_residuals!(residuals,
                           vec(y),
                           initialvalues,
                           terminalvalues,
                           exogenous,
                           dynamic_variables,
                           steadystate,
                           params,
                           m,
                           periods,
                           temp_vec,
                           )
    function J!(A::SparseArrays.SparseMatrixCSC{Float64, Int64}, y::AbstractVecOrMat{Float64})
        A = makeJacobian!(JJ, vec(y), initialvalues, terminalvalues, exogenous, context, periods, ws_threaded)
    end
    
    function fj!(residuals, JJ, y)
        f!(residuals, vec(y))
        J!(JJ, vec(y))
    end
           
    A0 = makeJacobian!(JJ, vec(y0), initialvalues, terminalvalues, exogenous, context, periods, ws_threaded)
    f!(residuals, vec(y0))
    J!(A0, y0)
    y00 = Vector{Float64}(undef, length(y0))
    df = OnceDifferentiable(f!, J!, vec(y0), residuals, A0)
    res = nlsolve(df, vec(y0))
end

function get_residuals!(
    residuals::AbstractVector{Float64},
    endogenous::AbstractVector{Float64},
    initialvalues::AbstractVector{Float64},
    terminalvalues::AbstractVector{Float64},
    exogenous::AbstractMatrix{Float64},
    dynamic_variables::AbstractVector{Float64},
    steadystate::AbstractVector{Float64},
    params::AbstractVector{Float64},
    m::Model,
    periods::Int64,
    temp_vec::AbstractVector{Float64},
)
    lli = m.lead_lag_incidence
    dynamic! = m.dynamic!.dynamic!
    n = m.endogenous_nbr

    get_residuals_1!(
        residuals,
        endogenous,
        initialvalues,
        exogenous,
        dynamic_variables,
        steadystate,
        params,
        m,
        periods,
        temp_vec,
    )
    t1 = n + 1
    t2 = 2 * n
    for t = 2:periods-1
        get_residuals_2!(
            residuals,
            endogenous,
            exogenous,
            dynamic_variables,
            steadystate,
            params,
            m,
            periods,
            temp_vec,
            t,
            t1,
            t2,
        )
        t1 += n
        t2 += n
    end
    get_residuals_3!(
        residuals,
        endogenous,
        terminalvalues,
        exogenous,
        dynamic_variables,
        steadystate,
        params,
        m,
        periods,
        temp_vec,
        periods,
        t1,
        t2,
    )
    return residuals
end

function get_residuals_1!(
    residuals::AbstractVector{Float64},
    endogenous::AbstractVector{Float64},
    initialvalues::AbstractVector{Float64},
    exogenous::AbstractMatrix{Float64},
    dynamic_variables::AbstractVector{Float64},
    steadystate::AbstractVector{Float64},
    params::AbstractVector{Float64},
    m::Model,
    periods::Int64,
    temp_vec::AbstractVector{Float64},
)
    lli = m.lead_lag_incidence
    dynamic! = m.dynamic!.dynamic!
    n = m.endogenous_nbr

    get_initial_dynamic_endogenous_variables!(
        dynamic_variables,
        endogenous,
        initialvalues,
        lli,
        2,
    )
    vr = view(residuals, 1:n)
    @inbounds Base.invokelatest(
        dynamic!,
        temp_vec,
        vr,
        dynamic_variables,
        exogenous,
        params,
        steadystate,
        2,
    )
end

function get_residuals_2!(
    residuals::AbstractVector{Float64},
    endogenous::AbstractVector{Float64},
    exogenous::AbstractMatrix{Float64},
    dynamic_variables::AbstractVector{Float64},
    steadystate::AbstractVector{Float64},
    params::AbstractVector{Float64},
    m::Model,
    periods::Int64,
    temp_vec::AbstractVector{Float64},
    t::Int64,
    t1::Int64,
    t2::Int64,
)
    lli = m.lead_lag_incidence
    dynamic! = m.dynamic!.dynamic!

    get_dynamic_endogenous_variables!(dynamic_variables, endogenous, lli, t)
    vr = view(residuals, t1:t2)
    @inbounds Base.invokelatest(
        dynamic!,
        temp_vec,
        vr,
        dynamic_variables,
        exogenous,
        params,
        steadystate,
        t,
    )
end

function get_residuals_3!(
    residuals::AbstractVector{Float64},
    endogenous::AbstractVector{Float64},
    terminalvalues::AbstractVector{Float64},
    exogenous::AbstractMatrix{Float64},
    dynamic_variables::AbstractVector{Float64},
    steadystate::AbstractVector{Float64},
    params::AbstractVector{Float64},
    m::Model,
    periods::Int64,
    temp_vec::AbstractVector{Float64},
    t::Int64,
    t1::Int64,
    t2::Int64,
)
    lli = m.lead_lag_incidence
    dynamic! = m.dynamic!.dynamic!

    get_terminal_dynamic_endogenous_variables!(
        dynamic_variables,
        endogenous,
        terminalvalues,
        lli,
        t,
    )
    vr = view(residuals, t1:t2)
    @inbounds Base.invokelatest(
        dynamic!,
        temp_vec,
        vr,
        dynamic_variables,
        exogenous,
        params,
        steadystate,
        t,
    )
end

