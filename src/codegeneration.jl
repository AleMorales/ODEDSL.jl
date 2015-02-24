########## Check units ###############

function calculate_units(exp::Expr, units::Dict{Symbol, Dimension}, c::Int64)
  ex = deepcopy(exp)
  for i in 1:length(ex.args)
    if isa(ex.args[i], Expr)
      ex.args[i], c = calculate_units(ex.args[i], units, c)
    elseif isa(ex.args[i], Symbol) && haskey(units, symbol(ex.args[i]))
      c += 1
      name = parse("__unit__$(c)")
      @eval global $name = ($(units[ex.args[i]]))
      ex.args[i] = name
    end
  end
  ex, c
end

function check_units(sorted_model::OdeSorted)
  given_units = Dict{Symbol, Dimension}()
  for (key,val) in sorted_model.Constants  given_units[symbol(key)] = val.Units.d end
  for (key,val) in sorted_model.Parameters  given_units[symbol(key)] = val.Units.d end
  for (key,val) in sorted_model.States  given_units[symbol(key)] = val.Units.d end
  for (key,val) in sorted_model.Forcings  given_units[symbol(key)] = val.Units.d end
  for level in sorted_model.SortedEquations
    for (key,val) in level  given_units[symbol(key)] = val.Units.d end
  end
  for level in sorted_model.SortedEquations[2:end]
    for (key,val) in level
      expected = given_units[symbol(key)]
      if isa(val.Expr, Symbol)
            infered = eval(given_units[val.Expr])
      else
        infered_expr, c = calculate_units(val.Expr, given_units, 0)
        infered = try eval(infered_expr) catch
            error("Error when calculating units: The rhs of equation $key is not dimensionally homogeneous.
The right hand side expression was $(val.Expr) with units $given_units") end
      end
      expected != infered && error("Error when calculating units: Expected and given units for $key did not coincide.
I infered the units $infered but you assign it $expected.
The right hand side expression was $(val.Expr) with units $given_units")
    end
  end
end

########## Generate Jacobian ###############

using Calculus

function generate_jacobian_function_Julia(model::OdeSorted, name)
  jacobian_matrix = generate_jacobian_matrix(model)
  string_assignments = [string(x[2].Expr) for x in model.SortedEquations[1]]
  code = string_assignments[1]*"\n"
  for i = 2:length(string_assignments)
    code *= string_assignments[i]*"\n"
  end
  for i = 1:size(jacobian_matrix)[1], j = 1:size(jacobian_matrix)[1]
    if isa(jacobian_matrix[i,j], Number) && eval(jacobian_matrix[i,j]) == 0
      continue
    else
      code *= "J[$i,$j] = $(jacobian_matrix[i,j])\n"
    end
  end
  return_line = "return nothing\n"
  function_text = paste("\n",
  "@inbounds function jacobian_$name(time::Float64, states::Array{Float64,1},
   params::Array{Float64,1}, forcs::Array{Float64,1}, J)\n", code, return_line,"end")
  return function_text
end

# Calculation Jacobian matrix of the model
function generate_jacobian_matrix(compressed_model::OdeSorted)
  names_states = collect(keys(compressed_model.States))
  names_derivatives = ["d_"*x*"_dt" for x in names_states]
  Jacobian = Array(Union(Expr, Symbol, Number),(length(names_states), length(names_states)))
  cd = 1
  for i in names_derivatives
    cs = 1
    for j in names_states
      Jacobian[cd,cs] =  differentiate(compressed_model.SortedEquations[2][i].Expr, parse(j))
      cs += 1
    end
    cd += 1
  end
  return Jacobian
end

########## Generate Extended System ###############

# Calculate extended system
function generate_extended_system(compressed_model::OdeSorted, name)
  sens_array = generate_sensitivity_array(compressed_model)
  # Create an extended ode system

  # Calculate the Jacobian of the extended system
  return "dummy_function", "dummy_jacobian"
end
# Calculate array of sensitivities
function generate_sensitivity_array(compressed_model::OdeSorted)
  names_states = collect(keys(compressed_model.States))
  names_derivatives = ["d_"*x*"_dt" for x in names_states]
  Sensitivity = Array{Union(Expr, Symbol, Number), 1}[]
  names_parameters = collect(keys(compressed_model.Parameters))
  for i in names_parameters
    sens = Array(Union(Expr, Symbol, Number), length(names_states))
    c = 1
    for j in names_derivatives
      sens[c] = differentiate(compressed_model.SortedEquations[2][j].Expr, parse(i))
      c += 1
    end
    push!(Sensitivity, sens)
  end
  return Sensitivity
end


####################################################################################
####################################################################################
##########################   JULIA CODE GENERATION #################################
####################################################################################
####################################################################################

# Create a return line when the output is a tuple of 2 arrays
function create_return_line_julia(states, observed)
    return_line = "(["
    for i in states
      if i != states[end]
        return_line = return_line  * i * ","
      else
        return_line = return_line  * i
      end
    end
    return_line = return_line * "], ["
    for i in observed
      if i != observed[end]
        return_line = return_line * i * ", "
      else
        return_line = return_line  * i
      end
    end
    return_line = return_line * "])"
end

# Create the function in Julia on the Equations section of the model Dict
function create_function_julia(model::OdeSorted, observed, name)
  code = ""
  for level in 1:length(model.SortedEquations)
    for (lhs, rhs) in model.SortedEquations[level]
        if level == 1
            code *= string(rhs.Expr) * "\n"
        else
                code *= lhs * " = " * string(rhs.Expr) * "\n"
        end
    end
  end
  # Determine what the time derivatives are
  time_derivatives = String[]
  for i in collect(keys(model.States))
    push!(time_derivatives, "d_"*i*"_dt")
  end
  # Return line
  return_line = create_return_line_julia(time_derivatives,observed)
  # Return the output
  code = replace(code, "1.0 *", "")
  return  paste("\n","@inbounds function $name(time::Float64, states::Array{Float64,1}, params::Array{Float64,1}, forcs::Array{Float64,1})\n", code, return_line,"end")
end

function generate_code_Julia!(ode_model::OdeSource; unit_analysis = true, name = "autogenerated_model", file = "autogenerated_model", jacobian = false, sensitivities = false)
  # Generate the observed variables (everything that is exported but it is not a time derivative)
  observed = String[]
  for (key,val) in ode_model.Equations
    val.Exported && push!(observed, key)
  end
  names_derivatives = collect(keys(ode_model.States))
  for i in 1:length(names_derivatives)
    names_derivatives[i] = "d_"*names_derivatives[i]*"_dt"
  end
  deleteat!(observed, findin(observed, names_derivatives))

  # Sort the equations
  sorted_model = sort_equations(ode_model);

  # Created compressed model (only if Jacobian or Sensitivities are required!)
  jacobian_function = "jacobian_$name() = nothing"
  sensitivity_function = "() -> ()"
  sensitivity_jacobian_function = "() -> ()"
  if jacobian || sensitivities
    compressed_model = compress_model(sorted_model, level = 2)
    jacobian && (jacobian_function = generate_jacobian_function(compressed_model, name))
    sensitivities && ((sensitivity_function, sensitivity_jacobian_function) = generate_extended_system(compressed_model, name))
  end

  # Check the units
  unit_analysis && check_units(sorted_model)

  # Generate the rhs function (compressed at level 2)
  model_function = create_function_julia(sorted_model,observed,name)

  # Create the default arguments
  named_states = OrderedDict{String, Any}()
  for (key,val) in sorted_model.States
    named_states[key] = val.Value * val.Units.f
  end
  named_parameters = OrderedDict{String, Any}()
  for (key,val) in sorted_model.Parameters
    named_parameters[key] = val.Value * val.Units.f
  end
  forcings = OrderedDict{String,Any}()
  c = 0
  for (key,value) in sorted_model.Forcings
      c += 1
      forcings[key] = (float(value.Time), float(value.Value)*value.Units.f)
  end
  write_model_Julia!(named_states,named_parameters, forcings, observed,
                  model_function,jacobian_function, name, file)
  nothing
end

function write_model_Julia!(States::OrderedDict{String, Any},
                            Parameters::OrderedDict{String, Any},
                            Forcings::OrderedDict{String, Any},
                            Observed::Array{String, 1},
                            Model::String,
                            Jacobian::String,
                            name::String,
                            file::String)
    f = open("$(file).jl","w")
    println(f, "import ODEDSL")
    println(f, "using DataStructures")
    println(f, "function generate_$name()")
    println(f, "States = OrderedDict{String, Any}()")
    for (key,val) in States
      println(f, "States[\"$key\"] = $val")
    end
    println(f, "Parameters = OrderedDict{String, Any}()")
    for (key,val) in Parameters
      println(f, "Parameters[\"$key\"] = $val")
    end
        println(f, "Forcings = OrderedDict{String, Any}()")
    for (key,val) in Forcings
      println(f, "Forcings[\"$key\"] = $val")
    end
    println(f, "Observed = $Observed")
    println(f, "$Model")
    println(f, "$Jacobian")
    println(f, "ODEDSL.DataTypes.OdeModel(States, Parameters, Forcings, Observed, $name, jacobian_$name)")
    println(f, "end")
    close(f)
    nothing
end

function generate_code_Julia!(source::String; unit_analysis = false, name = "autogenerated_model", file = "autogenerated_model", jacobian = false, sensitivities = false)
  parsed_model = process_file(source)
  reaction_model = convert_master_equation(parsed_model)
  ode_model = convert_reaction_model(reaction_model)
  generate_code_Julia!(ode_model, unit_analysis = unit_analysis, name = name, file = file, jacobian = jacobian, sensitivities = sensitivities)
end



####################################################################################
####################################################################################
############################   R CODE GENERATION ###################################
####################################################################################
####################################################################################

# Because Julia will use "pretty printing" for scalar product, we need to fool the parser
# by temporarily substituying by another binary operator and then doing string replacement
function sub_product(ex::Expr)
  for i in 1:length(ex.args)
  if ex.args[i] == :*
    ex.args[i] = :.*
  elseif isa(ex.args[i], Expr)
     ex.args[i] = sub_product(ex.args[i])
  end
end
return ex
end

sub_product(ex::Symbol) = ex

# Create a return line when the output is a list with two numeric vectors
function create_return_line_R(states, observed)
    return_line = "return(list(c("
    for i in states
      if i != states[end]
        return_line = return_line  * i * ","
      else
        return_line = return_line  * i
      end
    end
    return_line = return_line * "), c("
    for i in observed
      if i != observed[end]
        return_line = return_line * i * ", "
      else
        return_line = return_line  * i
      end
    end
    return_line = return_line * ")))"
end

# Create the function in R on the Equations section of the model Dict
function create_function_R!(model::OdeSorted, observed)
  code = ""
  for level in 1:length(model.SortedEquations)
    for (lhs, rhs) in model.SortedEquations[level]
        if level == 1
            code *= string(rhs.Expr) * "\n"
        else
                code *= lhs * " = " * replace(string(rhs.Expr), ".*", "*") * "\n"
        end
    end
  end
  # Determine what the time derivatives are
  time_derivatives = String[]
  for i in collect(keys(model.States))
    push!(time_derivatives, "d_"*i*"_dt")
  end
  # Return line
  return_line = create_return_line_R(time_derivatives,observed)
  # Return the output
  code = replace(code, "1.0 *", "")
  return  paste("\n","function(time, states, params, forcs) { \n", code, return_line,"}")
end

function generate_code_R!(ode_model::OdeSource; unit_analysis = true, name = "autogenerated_model", file = "autogenerated_model", jacobian = false, sensitivities = false)
  # Generate the observed variables (everything that is exported but it is not a time derivative)
  observed = String[]
  for (key,val) in ode_model.Equations
    val.Exported && push!(observed, key)
  end
  names_derivatives = collect(keys(ode_model.States))
  for i in 1:length(names_derivatives)
    names_derivatives[i] = "d_"*names_derivatives[i]*"_dt"
  end
  deleteat!(observed, findin(observed, names_derivatives))

  # Sort the equations
  sorted_model = sort_equations(ode_model)

  # Created compressed model (only if Jacobian or Sensitivities are required!)
  jacobian_function = "() -> ()"
  sensitivity_function = "() -> ()"
  sensitivity_jacobian_function = "() -> ()"
  if jacobian || sensitivities
    compressed_model = compress_model(sorted_model, level = 2)
    jacobian && (jacobian_function = generate_jacobian_function(compressed_model, name))
    sensitivities && ((sensitivity_function, sensitivity_jacobian_function) = generate_extended_system(compressed_model, name))
  end

  # Check the units
  unit_analysis &&  check_units(sorted_model)

  # Go through the equations and substitute * by ×
  for i in 1:length(sorted_model.SortedEquations)
      for (key,val) in sorted_model.SortedEquations[i]
         sorted_model.SortedEquations[i][key].Expr = sub_product(sorted_model.SortedEquations[i][key].Expr)
      end
  end

  # Generate the rhs function
  model_function = create_function_R!(sorted_model,observed)

  # Create the default arguments
  named_states = OrderedDict{String, Any}()
  for (key,val) in sorted_model.States
    named_states[key] = val.Value * val.Units.f
  end
  named_parameters = OrderedDict{String, Any}()
  for (key,val) in sorted_model.Parameters
    named_parameters[key] = val.Value * val.Units.f
  end
  forcings = OrderedDict{String,Any}()
  c = 0
  for (key,value) in sorted_model.Forcings
      c += 1
      forcings[key] = (float(value.Time), float(value.Value)*value.Units.f)
  end
  write_model_R!(named_states,named_parameters, forcings, observed,
                  model_function, name, file)
  nothing
end


function write_model_R!(States::OrderedDict{String, Any},
                            Parameters::OrderedDict{String, Any},
                            Forcings::OrderedDict{String, Any},
                            Observed::Array{String, 1},
                            Model::String,
                            name::String,
                            file::String)
    f = open("$(file).R","w")
    println(f, "library(simecol); library(RcppSundials)")
    println(f, "$name <- new(\"odeModel\",")
    println(f, "main = $Model, ")
    transformed_states = string(States)[2:(end-1)]
    transformed_states = replace(transformed_states, "=>", "=")
    println(f, "init = c($transformed_states),")
    transformed_parameters = string(Parameters)[2:(end-1)]
    transformed_parameters = replace(transformed_parameters, "=>", "=")
    println(f, "parms = c($transformed_parameters),")
    println(f, "inputs = list(")
    forcs = ""
    for (key,val) in Forcings
      forcs *= "$key = cbind(c($(string(val[1])[2:(end-1)])),c($(string(val[2])[2:(end-1)]))),"
    end
    forcs = forcs[1:(end-1)]
    println(f, forcs)
    println(f, "),")
    println(f, "times = 0:1,")
    names_observed = string(Observed)[8:(end-1)]
    names_states = string(collect(keys(States)))[8:(end-1)]
    println(f, """
solver = function(y, times, func, parms, inputs) {
sim = as.matrix(cvode_R(times = times, states = y,
        parameters = parms,
        forcings_data = inputs,
        settings = list(rtol = 1e-6,
                  atol = 1e-6, maxsteps = 1e3, maxord = 5, hini = 1e-3,
                  hmin = 0, hmax = 100, maxerr = 5, maxnonlin = 10,
                  maxconvfail = 10, method = "bdf", maxtime = 1, jacobian = 0),
        model = func, jacobian = function(t, states, parameters, forcings) {0}))
colnames(sim) = c(\"time\", $names_states, $names_observed)
class(sim) = c(\"deSolve\",\"matrix\")
sim
})
test = sim($name)
""")
    close(f)
    nothing
end


function generate_code_R!(source::String; unit_analysis = false,name = "autogenerated_model", file = "autogenerated_model", jacobian = false, sensitivities = false)
  parsed_model = process_file(source)
  reaction_model = convert_master_equation(parsed_model)
  ode_model = convert_reaction_model(reaction_model)
  generate_code_R!(ode_model, unit_analysis = unit_analysis, name = name, file = file, jacobian = jacobian, sensitivities = sensitivities)
end
