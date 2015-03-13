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
        return_line *= i * ","
      else
        return_line *= i
      end
    end
    return_line *= ")"
    length(observed) > 0 && (return_line *= ", c(")
    for i in observed
      if i != observed[end]
        return_line = return_line * i * ", "
      else
        return_line = return_line  * i
      end
    end
    length(observed) > 0 && (return_line *= ")")
    return_line = return_line * "))"
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
  observed = ASCIIString[]
  for (key,val) in ode_model.Equations
    val.Exported && push!(observed, key)
  end
  names_derivatives = collect(keys(ode_model.States))
  for i in 1:length(names_derivatives)
    names_derivatives[i] = "d_"*names_derivatives[i]*"_dt"
  end
  deleteat!(observed, findin(observed, names_derivatives))
  coef_observed = OrderedDict{ASCIIString, Float64}()
  for i in observed
    coef_observed[i] = ode_model.Equations[i].Units.f
  end

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
  named_states = OrderedDict{ASCIIString, Float64}()
  coef_states = OrderedDict{ASCIIString, Float64}()
  for (key,val) in sorted_model.States
    named_states[key] = val.Value * val.Units.f
    coef_states[key] = val.Units.f
  end
  named_parameters = OrderedDict{ASCIIString, Float64}()
  coef_parameters = OrderedDict{ASCIIString, Float64}()
  for (key,val) in sorted_model.Parameters
    named_parameters[key] = val.Value * val.Units.f
    coef_parameters[key] = val.Units.f
  end
  forcings = OrderedDict{ASCIIString,Any}()
  coef_forcings = OrderedDict{ASCIIString,Float64}()
  c = 0
  for (key,value) in sorted_model.Forcings
      c += 1
      forcings[key] = (float(value.Time), float(value.Value)*value.Units.f)
      coef_forcings[key] = value.Units.f
  end
  write_model_R!(named_states,coef_states, named_parameters, coef_parameters,
                 forcings, coef_forcings, observed,coef_observed,
                  model_function, name, file)
  nothing
end

function write_model_R!(States::OrderedDict{ASCIIString, Float64},
                        Coef_states::OrderedDict{ASCIIString, Float64},
                        Parameters::OrderedDict{ASCIIString, Float64},
                        Coef_parameters::OrderedDict{ASCIIString, Float64},
                        Forcings::OrderedDict{ASCIIString, Any},
                        Coef_forcings::OrderedDict{ASCIIString, Float64},
                        Observed::Array{ASCIIString, 1},
                        Coef_observed::OrderedDict{ASCIIString, Float64},
                        Model::ASCIIString,
                        name::ASCIIString,
                        file::ASCIIString)
    f = open("$(file).R","w")
    println(f, "library(SimulationModels); library(RcppSundials)")
    println(f, "$name <- ODEmodel\$new(")
    transformed_states = string(States)[2:(end-1)]
    transformed_states = replace(transformed_states, "=>", "=")
    units = replace(string(Coef_states)[2:(end-1)], "=>", "=")
    println(f, "States = list(Values = c($transformed_states), Coefs = c($units)),")
    transformed_parameters = string(Parameters)[2:(end-1)]
    transformed_parameters = replace(transformed_parameters, "=>", "=")
    units = replace(string(Coef_parameters)[2:(end-1)], "=>", "=")
    println(f, "Parameters = list(Values = c($transformed_parameters), Coefs = c($units)),")
    if length(Forcings) > 0
      println(f, "Forcings = list(Values = list(")
      forcs = ""
      for (key,val) in Forcings
        forcs *= "$key = cbind(c($(string(val[1])[2:(end-1)])),c($(string(val[2])[2:(end-1)]))),"
      end
      forcs = forcs[1:(end-1)]
      println(f, forcs)
      units = replace(string(Coef_forcings)[2:(end-1)], "=>", "=")
      println(f, "), Coefs = c($units)),")
    end
    println(f, "Time = 0:1,")
    names_observed = string(Observed)[13:(end-1)]
    units = replace(string(Coef_observed)[2:(end-1)], "=>", "=")
    println(f, "Observed = list(names = c($names_observed), Coefs = c($units)),")
    println(f, """
    Settings = list(rtol = 1e-6,atol = 1e-10, maxsteps = 1e5, maxord = 5, hini = 0,
                      hmin = 0, hmax = 0, maxerr = 12, maxnonlin = 12,
                      maxconvfail = 12, method = "bdf", maxtime = 0, jacobian = 0),
""")
    println(f, "model = $Model)")
    close(f)
    nothing
end


function generate_code_R!(source::String; unit_analysis = false,name = "autogenerated_model", file = "autogenerated_model", jacobian = false, sensitivities = false)
  parsed_model = process_file(source)
  reaction_model = convert_master_equation(parsed_model)
  ode_model = convert_reaction_model(reaction_model)
  generate_code_R!(ode_model, unit_analysis = unit_analysis, name = name, file = file, jacobian = jacobian, sensitivities = sensitivities)
end
