include("makeA.jl")
include("PATH_interface.jl")

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
@enum InitializationAlgo datafile steadystate firstorder linearinterpolation

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
    df = context.dynarefunctions
    ncol = m.n_bkwrd + m.n_current + m.n_fwrd + 2 * m.n_both
    tmp_nbr = df.dynamic!.tmp_nbr::Vector{Int64}
    dynamic_ws = DynamicWs(m.endogenous_nbr, m.exogenous_nbr, ncol, sum(tmp_nbr[1:2]))
    perfect_foresight_ws = PerfectForesightWs(context, periods)
    X = perfect_foresight_ws.shocks
    guess_values = perfect_foresight_initialization!(context, periods, datafile, X, perfect_foresight_ws, steadystate, dynamic_ws)
    if get(field["options"], "lmmcp.status", false)
        mcp_perfectforesight_core!(perfect_foresight_ws, context, periods, guess_values, dynamic_ws)
    perfectforesight_core!(perfect_foresight_ws, context, periods, guess_values, dynamic_ws)
end

function perfect_foresight_initialization!(context, periods, datafile, exogenous, perfect_foresight_ws, algo::InitializationAlgo, dynamic_ws::DynamicWs)
    if algo == datafile
    elseif algo == steadystate
        compute_steady_state!(context)
        endogenous_steady_state = context.results.model_results[1].trends.endogenous_steady_state
        initial_values = repeat(endogenous_steady_state, 1, periods)
    elseif algo == firstorder
        initial_values = simul_first_order!(context, periods, exogenous, dynamic_ws)
    elseif algo == interpolation
    end
    return initial_values
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
    if modfileinfo.has_histval
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
    ddf = context.dynarefunctions
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

    function f!(residuals, y)
        @debug "$(now()): start f!"
        get_residuals!(residuals,
                       vec(y),
                       initialvalues,
                       terminalvalues,
                       exogenous,
                       dynamic_variables,
                       steadystate,
                       params,
                       m,
                       ddf,
                       periods,
                       temp_vec,
                       )
        @debug "$(now()): end f!"
    end
    
    function J!(A::SparseArrays.SparseMatrixCSC{Float64, Int64}, y::AbstractVecOrMat{Float64})
        @debug "$(now()): start J!"
        A = makeJacobian!(JJ, vec(y), initialvalues, terminalvalues, exogenous, context, periods, ws_threaded)
        @debug count(!iszero, A)/prod(size(A))
        @debug "$(now()): end J!"
    end
    
    function fj!(residuals, JJ, y)
        f!(residuals, vec(y))
        J!(JJ, vec(y))
    end

    @debug "$(now()): start makeJacobian"
    A0 = makeJacobian!(JJ, vec(y0), initialvalues, terminalvalues, exogenous, context, periods, ws_threaded)
    @debug "$(now()): end makeJacobian"
    @debug "$(now()): start f!"
    f!(residuals, vec(y0))
    @debug "$(now()): end f!"
    @debug "$(now()): start J!"
    J!(A0, y0)
    @debug "$(now()): end J!"
    df = OnceDifferentiable(f!, J!, vec(y0), residuals, A0)
    @debug "$(now()): start nlsolve"

    rr = copy(residuals)
    F = lu(A0)
    res = nlsolve(df, vec(y0), method=:robust_trust_region, show_trace=true)
    @debug "$(now()): end nlsolve"
    endogenous_names = get_endogenous_longname(context.symboltable)
    push!(context.results.model_results[1].simulations,
          Simulation("Sim1", "", TimeDataFrame(DataFrame(transpose(reshape(res.zero, m.endogenous_nbr, periods)),
                                                         endogenous_names),
                                               UndatedDate(1))))
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
    df::DynareFunctions,
    periods::Int64,
    temp_vec::AbstractVector{Float64};
    permutations::Vector{Pair{Int64, Int64}} = Pair{Int64, Int64}[]
)
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
        df,
        periods,
        temp_vec,
        permutations
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
            df,
            periods,
            temp_vec,
            t,
            t1,
            t2,
            permutations
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
        df,
        periods,
        temp_vec,
        periods,
        t1,
        t2,
        permutations
    )
    return residuals
end

inline function reorder1!(x, permutations, n)
    isempty(permutations) && return
    reorder!(x, permutations, 0)
    reorder!(x, permutations, n)
end

inline function reorder2!(x, permutations, t, n)
    isempty(permutations) && return
    reorder!(x, permutations, (t - 2)*n)
    reorder!(x, permutations, (t - 1)*n)
    reorder!(x, permutations, t*n)
end

inline function reorder3!(x, permutations, t, n)
    isempty(permutations) && return
    reorder!(x, permutations, (t - 2)*n)
    reorder!(x, permutations, (t - 1)*n)
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
    df::DynareFunctions,
    periods::Int64,
    temp_vec::AbstractVector{Float64};
    permutations::Vector{Pair{Int64, Int64}} = Pair{Int64, Int64}[]
)
    lli = m.lead_lag_incidence
    dynamic! = df.dynamic!.dynamic!
    n = m.endogenous_nbr

    end
    reorder1!(endogenous, permutations, m.endogenous_nbr)
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
    reorder1!(endogenous, permutations, m.endogenous_nbr)
end

function get_residuals_2!(
    residuals::AbstractVector{Float64},
    endogenous::AbstractVector{Float64},
    exogenous::AbstractMatrix{Float64},
    dynamic_variables::AbstractVector{Float64},
    steadystate::AbstractVector{Float64},
    params::AbstractVector{Float64},
    m::Model,
    df::DynareFunctions,
    periods::Int64,
    temp_vec::AbstractVector{Float64},
    t::Int64,
    t1::Int64,
    t2::Int64;
    permutations::Vector{Pair{Int64, Int64}} = Pair{Int64, Int64}[]
)
    lli = m.lead_lag_incidence
    dynamic! = df.dynamic!.dynamic!

    reorder2!(endogenous, permutations, t, m.endogenous_nbr)
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
    reorder2!(endogenous, permutations, t, m.endogenous_nbr)
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
    df::DynareFunctions,
    periods::Int64,
    temp_vec::AbstractVector{Float64},
    t::Int64,
    t1::Int64,
    t2::Int64;
    permutations::Vector{Pair{Int64, Int64}} = Pair{Int64, Int64}[]
)
    lli = m.lead_lag_incidence
    dynamic! = df.dynamic!.dynamic!

    reorder3!(endogenous, permutations, t, m.endogenous_nbr)
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
    if !isempty(permutations)
        reorder!(endogenous, permuations, (t - 2)*m.endogenous_nbr)
        reorder!(endogenous, permuations, (t - 1)*m.endogenous_nbr)
    end
    reorder3!(endogenous, permutations, t, m.endogenous_nbr)
end


