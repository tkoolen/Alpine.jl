"""

    create_bounding_mip(m::PODNonlinearModel; use_discretization::Dict)

Set up a JuMP MILP bounding model base on variable domain partitioning information stored in `use_discretization`.
By default, if `use_discretization is` not provided, it will use `m.discretizations` store in the POD model.
The basic idea of this MILP bounding model is to use Tighten McCormick to convexify the original Non-convex region.
Among all presented partitionings, the bounding model will choose one specific partition as the lower bound solution.
The more partitions there are, the better or finer bounding model relax the original MINLP while the more
efforts required to solve this MILP is required.

This function is implemented in the following manner:

    * [`amp_post_vars`](@ref): post original and lifted variables
    * [`amp_post_lifted_constraints`](@ref): post original and lifted constraints
    * [`amp_post_lifted_obj`](@ref): post original or lifted objective function
    * [`amp_post_tmc_mccormick`](@ref): post Tighen McCormick variables and constraints base on `discretization` information

More specifically, the Tightening McCormick used here can be genealized in the following mathematcial formulation. Consider a nonlinear term
```math
\\begin{subequations}
\\begin{align}
   &\\widehat{x_{ij}} \\geq (\\mathbf{x}_i^l\\cdot\\hat{\\mathbf{y}}_i) x_j + (\\mathbf{x}_j^l\\cdot\\hat{\\mathbf{y}}_j) x_i - (\\mathbf{x}_i^l\\cdot\\hat{\\mathbf{y}}_i)(\\mathbf{x}_j^l\\cdot\\hat{\\mathbf{y}}_j) \\\\
   &\\widehat{x_{ij}} \\geq (\\mathbf{x}_i^u\\cdot\\hat{\\mathbf{y}}_i) x_j + (\\mathbf{x}_j^u\\cdot\\hat{\\mathbf{y}}_j) x_i - (\\mathbf{x}_i^u\\cdot\\hat{\\mathbf{y}}_i)(\\mathbf{x}_j^u\\cdot\\hat{\\mathbf{y}}_j) \\\\
   &\\widehat{x_{ij}} \\leq (\\mathbf{x}_i^l\\cdot\\hat{\\mathbf{y}}_i) x_j + (\\mathbf{x}_j^u\\cdot\\hat{\\mathbf{y}}_j) x_i - (\\mathbf{x}_i^l\\cdot\\hat{\\mathbf{y}}_i)(\\mathbf{x}_j^u\\cdot\\hat{\\mathbf{y}}_j) \\\\
   &\\widehat{x_{ij}} \\leq (\\mathbf{x}_i^u\\cdot\\hat{\\mathbf{y}}_i) x_j + (\\mathbf{x}_j^l\\cdot\\hat{\\mathbf{y}}_j) x_i - (\\mathbf{x}_i^u\\cdot\\hat{\\mathbf{y}}_i)(\\mathbf{x}_j^l\\cdot\\hat{\\mathbf{y}}_j) \\\\
   & \\mathbf{x}_i^u\\cdot\\hat{\\mathbf{y}}_i) \\geq x_{i} \\geq \\mathbf{x}_i^l\\cdot\\hat{\\mathbf{y}}_i) \\\\
   & \\mathbf{x}_j^u\\cdot\\hat{\\mathbf{y}}_j) \\geq x_{j} \\geq \\mathbf{x}_j^l\\cdot\\hat{\\mathbf{y}}_j) \\\\
   &\\sum \\hat{\\mathbf{y}_i} = 1, \\ \\ \\sum \\hat{\\mathbf{y}_j}_k = 1 \\\\
   &\\hat{\\mathbf{y}}_i \\in \\{0,1\\}, \\hat{\\mathbf{y}}_j \\in \\{0,1\\}
\\end{align}
\\end{subequations}
```

"""
function create_bounding_mip(m::PODNonlinearModel; kwargs...)

    options = Dict(kwargs)

    haskey(options, :use_discretization) ? discretization = options[:use_discretization] : discretization = m.discretization

    m.model_mip = Model(solver=m.mip_solver) # Construct JuMP Model
    start_build = time()
    # ------- Model Construction ------ #
    amp_post_vars(m)                                                # Post original and lifted variables
    amp_post_lifted_constraints(m)                                  # Post lifted constraints
    amp_post_lifted_objective(m)                                    # Post objective
    amp_post_convexification(m, use_discretization=discretization)  # Convexify problem
    # --------------------------------- #
    cputime_build = time() - start_build
    m.logs[:total_time] += cputime_build
    m.logs[:time_left] = max(0.0, m.timeout - m.logs[:total_time])

    return
end

"""
    amp_post_convexification(m::PODNonlinearModel; kwargs...)

warpper function to convexify the problem for a bounding model. This function talks to nonlinear_info and convexification methods
to finish the last step required during the construction of bounding model.
"""
function amp_post_convexification(m::PODNonlinearModel; kwargs...)

    options = Dict(kwargs)

    haskey(options, :use_discretization) ? discretization = options[:use_discretization] : discretization = m.discretization

    for i in 1:length(m.method_convexification)             # Additional user-defined convexification method
        eval(m.method_convexification[i])(m)
    end

    amp_post_mccormick(m, use_discretization=discretization)    # handles all bi-linear and monomial convexificaitons
    amp_post_convhull(m, use_discretization=discretization)         # convex hull representation
    convexification_exam(m)

    return
end

function amp_post_vars(m::PODNonlinearModel; kwargs...)

    options = Dict(kwargs)

    if haskey(options, :use_discretization)
        l_var = [options[:use_discretization][i][1]   for i in 1:(m.num_var_orig+m.num_var_lifted_mip)]
        u_var = [options[:use_discretization][i][end] for i in 1:(m.num_var_orig+m.num_var_lifted_mip)]
    else
        l_var = m.l_var_tight
        u_var = m.u_var_tight
    end

    @variable(m.model_mip, x[i=1:(m.num_var_orig+m.num_var_lifted_mip)])
    for i in 1:(m.num_var_orig+m.num_var_lifted_mip)
        (i <= m.num_var_orig) && setcategory(x[i], m.var_type_orig[i])
        (l_var[i] > -Inf) && (setlowerbound(x[i], l_var[i]))   # Changed to tight bound, if no bound tightening is performed, will be just .l_var_orig
        (u_var[i] < Inf) && (setupperbound(x[i], u_var[i]))   # Changed to tight bound, if no bound tightening is performed, will be just .u_var_orig
    end

    return
end

function amp_post_lifted_constraints(m::PODNonlinearModel)

    for i in 1:m.num_constr_orig
        if m.constr_type_orig[i] == :(>=)
            @constraint(m.model_mip,
                sum(m.lifted_constr_aff_mip[i][:coefs][j]*Variable(m.model_mip, m.lifted_constr_aff_mip[i][:vars][j].args[2]) for j in 1:m.lifted_constr_aff_mip[i][:cnt]) >= m.lifted_constr_aff_mip[i][:rhs])
        elseif m.constr_type_orig[i] == :(<=)
            @constraint(m.model_mip,
                sum(m.lifted_constr_aff_mip[i][:coefs][j]*Variable(m.model_mip, m.lifted_constr_aff_mip[i][:vars][j].args[2]) for j in 1:m.lifted_constr_aff_mip[i][:cnt]) <= m.lifted_constr_aff_mip[i][:rhs])
        elseif m.constr_type_orig[i] == :(==)
            @constraint(m.model_mip,
                sum(m.lifted_constr_aff_mip[i][:coefs][j]*Variable(m.model_mip, m.lifted_constr_aff_mip[i][:vars][j].args[2]) for j in 1:m.lifted_constr_aff_mip[i][:cnt]) == m.lifted_constr_aff_mip[i][:rhs])
        end
    end

    return
end

function amp_post_lifted_objective(m::PODNonlinearModel)
    @objective(m.model_mip, m.sense_orig, sum(m.lifted_obj_aff_mip[:coefs][i]*Variable(m.model_mip, m.lifted_obj_aff_mip[:vars][i].args[2]) for i in 1:m.lifted_obj_aff_mip[:cnt]))
    return
end



"""
    add_discretization(m::PODNonlinearModel; use_discretization::Dict, use_solution::Vector)

Basic built-in method used to add a new partition on feasible domains of discretizing variables.
This method make modification in .discretization

Consider original partition [0, 3, 7, 9], where LB/any solution is 4.
Use ^ as the new partition, "|" as the original partition

A case when discretize ratio = 4
| -------- | - ^ -- * -- ^ ---- | -------- |
0          3  3.5   4   4.5     7          9

A special case when discretize ratio = 2
| -------- | ---- * ---- ^ ---- | -------- |
0          3      4      5      7          9

There are two options for this function,

    * `use_discretization(default=m.discretization)`:: to regulate which is the base to add new partitions on
    * `use_solution(default=m.best_bound_sol)`:: to regulate which solution to use when adding new partitions on

This function belongs to the hackable group, which means it can be replaced by the user to change the behvaior of the solver.
"""
function add_discretization(m::PODNonlinearModel; kwargs...)

    options = Dict(kwargs)

    haskey(options, :use_discretization) ? discretization = options[:use_discretization] : discretization = m.discretization
    haskey(options, :use_solution) ? point_vec = options[:use_solution] : point_vec = m.best_bound_sol

    # ? Perform discretization base on type of nonlinear terms

    for i in 1:m.num_var_orig
        point = point_vec[i]
        @assert point >= discretization[i][1] - m.tol       # Solution validation
        @assert point <= discretization[i][end] + m.tol
        # Safety Scheme
        (abs(point - discretization[i][1]) <= m.tol) && (point = discretization[i][1])
        (abs(point - discretization[i][end]) <= m.tol) && (point = discretization[i][end])
        if i in m.var_discretization_mip  # Only construct when discretized
            for j in 1:length(discretization[i])
                if point >= discretization[i][j] && point <= discretization[i][j+1]  # Locating the right location
                    @assert j < length(m.discretization[i])
                    lb_local = discretization[i][j]
                    ub_local = discretization[i][j+1]
                    distance = ub_local - lb_local
                    radius = distance / m.discretization_ratio
                    lb_new = max(point - radius, lb_local)
                    ub_new = min(point + radius, ub_local)
                    if ub_new < ub_local && !isapprox(ub_new, ub_local; atol=m.tol)  # Insert new UB-based partition
                        insert!(discretization[i], j+1, ub_new)
                    end
                    if lb_new > lb_local && !isapprox(lb_new, lb_local; atol=m.tol)  # Insert new LB-based partition
                        insert!(discretization[i], j+1, lb_new)
                    end
                    m.log_level > 99 && println("[DEBUG] VAR$(i): SOL=$(round(point,4)) RATIO=$(m.discretization_ratio), PARTITIONS=$(length(discretization[i]))  |$(round(lb_local,4)) |$(round(lb_new,6)) <- * -> $(round(ub_new,6))| $(round(ub_local,4))|")
                    break
                end
            end
        end
    end

    return discretization
end
