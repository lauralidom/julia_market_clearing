module HelperInputData

# adds noise to the input Q_gen_window for generator g from first_hour to last_hour. constrained by total_capacity and with magnitude noise_std

function add_noise!(Q_gen_window, g, total_capacity, noise_std, first_hour, last_hour)
	
	# note: we could have some different strategies here

	for h in first_hour:last_hour
        # Current forecast (availability factor)
        current_af = Q_gen_window[(g, h)] / total_capacity
        
        # Add Gaussian noise
        noise = randn() * noise_std
        new_af = clamp(current_af + noise, 0.0, 1.0) # constraint 0 => total_capacity
        
        Q_gen_window[(g, h)] = total_capacity * new_af
    end
end

end;