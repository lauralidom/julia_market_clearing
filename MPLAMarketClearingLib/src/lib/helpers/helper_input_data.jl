module HelperInputData

# adds noise to the input Q_gen_window for generator g from first_time_period to last_time_period. constrained by total_capacity and with magnitude noise_std

function add_noise!(Q_gen_window, g, total_capacity, noise_std, first_time_period, last_time_period)
	lineardecay = true # todo: make this configurable
	# note: we could have some different strategies here

	for t in first_time_period:last_time_period
        # Current forecast (availability factor)
        current_af = Q_gen_window[(g, t)] / total_capacity
        
        decayfactor = 0
        if lineardecay
            decayfactor = ((t - first_time_period)/(last_time_period-first_time_period)) # 0 for first time period, 1 for last, linear in between
        end
        # Add Gaussian noise
        noise = randn() * noise_std * decayfactor * current_af # last factor makes this proportional
        new_af = clamp(current_af + noise, 0.0, 1.0) # constraint 0 => total_capacity
        
        Q_gen_window[(g, t)] = total_capacity * new_af
    end
end



function add_noise_pre!(input_profile, noise_std, first_time_period, last_time_period)
    lineardecay = false # todo: make this configurable
    expdecay = true
    # note: we could have some different strategies here

    for t in first_time_period:last_time_period
        # Current forecast (availability factor)
        to_update = ( t % length(input_profile) ) + 1 # it's 1 indexed
        current_af = input_profile[to_update]
        
        decayfactor = 0
        if lineardecay
            decayfactor = ((t - first_time_period)/(last_time_period-first_time_period)) # 0 for first time period, 1 for last, linear in between
        end
        if expdecay
           decayfactor = (.95*(1 - .04)^t) + .05 # trying some test values for the exponential decay
        end
        if decayfactor < 0 || decayfactor > 1 || isnan(decayfactor)
            println("decay factor out of range", decayfactor, t, first_time_period, last_time_period)
        end
        # Add Gaussian noise
        noise = randn() * noise_std * decayfactor * current_af # last factor makes this proportional
        new_af = clamp(current_af + noise, 0.0, 1.0) # constraint 0 => 1
        if isnan(new_af)
            println("is nan ", noise, new_af)
            new_af = 0.0
        end
        input_profile[to_update] = new_af
    end
    return input_profile
end

end;