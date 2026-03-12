
function generate_wind_forecast_for_days(data, output_file, n_days)

	windBaseline = data[:variableGenerators]["Wind"]

	matrix_size = n_days*data[:timePeriodsPerDay] + 1

	noise_std = .03 # data[:noiseLevel]

	lineardecay = true

	convergence_period_length = data[:timePeriodsPerDay] # silly assumption that forecasts don't start to converge until 24 hrs ahead - note: this all needs to be rethought

	#create matrix with zeros to start
	windData = zeros(Float64, matrix_size, matrix_size)

	# an m x n matrix

	# m is the column = delivery time
	# n is the row = forecast time

	# for every forecast time (each row)
	for n in 1:matrix_size
		# each column should update the wind forecast across time
		for m in 1:matrix_size

			if n == 1 # first row is special, uses input data
				# println(windBaseline["profile"][m%length(windBaseline["profile"]) + 1])
				windData[n, m] = windBaseline["profile"][m%length(windBaseline["profile"]) + 1]
				
			
			# if the delivery time is greater than the forecast time, we've realized our production don't update it
			elseif  m > n 

		        decayfactor = 0
		        if lineardecay && m - n < convergence_period_length
		            decayfactor = ((m - n)/convergence_period_length) # 0 for first time period, 1 for last, linear in between
		        end
		        # Add Gaussian noise
		        lastForecast = windData[n-1, m]
		        if lastForecast == 0.0
		        	lastForecast = windData[1, m]
		        end

		        noise = randn() * noise_std * decayfactor # * lastForecast - optional last factor to make this proportional
		        new_af = clamp(lastForecast + noise, 0.0, 1.0) # constraint 0 => total_capacity
				windData[n, m] = new_af
			end 
		end
	end

	return windData
end;