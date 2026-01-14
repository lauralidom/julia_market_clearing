module HelperInputData

# adds noise to the input Q_gen_window for generator g from first_hour to last_hour. constrained by total_capacity and with magnitude noise_std

function add_noise!(Q_gen_window, g, total_capacity, noise_std, first_hour, last_hour)
	lineardecay = true # todo: make this configurable
	# note: we could have some different strategies here

	for h in first_hour:last_hour
        # Current forecast (availability factor)
        current_af = Q_gen_window[(g, h)] / total_capacity
        
        decayfactor = 0
        if lineardecay
            decayfactor = ((h - first_hour)/(last_hour-first_hour)) # 0 for first hour, 1 for last, linear in between
        end
        # Add Gaussian noise
        noise = randn() * noise_std * decayfactor * current_af # last factor makes this proportional
        new_af = clamp(current_af + noise, 0.0, 1.0) # constraint 0 => total_capacity
        
        Q_gen_window[(g, h)] = total_capacity * new_af
    end
end

end;