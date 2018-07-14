function gsreg(
        depvar,
        expvars,
        data;
        intercept=nothing,
        outsample=nothing,
        samesample=nothing,
        criteria=nothing,
        ttest=nothing,
        vectoroperation=nothing,
        modelavg=nothing,
        summary=nothing,
        datanames=nothing,
        datatype=nothing,
        orderresults=nothing
    )
    result = GSRegResult(
        depvar,
        expvars,
        data,
        intercept,
        outsample,
        samesample,
        criteria,
        ttest,
        vectoroperation,
        modelavg,
        datanames,
        datatype,
        orderresults
    )
    proc!(result)
    if summary != nothing
        f = open(summary, "w")
        write(f, to_string(result))
        close(f)
    end
    return result
end

function gsreg_single_proc_result!(data, results, intercept, outsample, criteria, ttest, vectoroperation, datanames, datatype, header, order)
    cols = get_selected_cols(order)
    data_cols_num = size(data, 2)
    if intercept
        append!(cols, data_cols_num)
    end 

    depvar = @view(data[1:end-outsample, 1])
    expvars = @view(data[1:end-outsample, cols])

    nobs = size(depvar, 1)
    ncoef = size(expvars, 2)
    qrf = qrfact(expvars)
    b = qrf \ depvar                        # estimate
    er = depvar - expvars * b               # in-sample residuals
    sse = sum(er .^ 2)                      # residual sum of squares
    df_e = nobs - ncoef                     # degrees of freedom
    rmse = sqrt(sse / nobs)                 # root mean squared error
    r2 = 1 - var(er) / var(depvar)          # model R-squared

    if ttest
        bstd = sqrt.(sum( (UpperTriangular(qrf[:R]) \ eye(ncoef)) .^ 2, 2) * (sse / df_e) ) # std deviation of coefficients
    end

    if outsample > 0
        depvar_out = @view(data[end-outsample:end, 1])
        expvars_out = @view(data[end-outsample:end, cols])
        erout = depvar_out - expvars_out * b          # out-of-sample residuals
        sseout = sum(erout .^ 2)                      # residual sum of squares
        rmseout = sqrt(sseout / outsample)            # root mean squared error
        results[order, header[:rmseout]] = rmseout
    end

    results[order, header[:index]] = order

    for (index, col) in enumerate(cols)
        results[order, header[Symbol(string(datanames[col], "_b"))]] = datatype(b[index])
        if ttest == true
            results[order, header[Symbol(string(datanames[col], "_bstd"))]] = datatype(bstd[index])
        end
    end

    results[order, header[:nobs]] = nobs
    results[order, header[:ncoef]] = ncoef
    results[order, header[:sse]] = datatype(sse)
    results[order, header[:r2]] = datatype(r2)
    results[order, header[:rmse]] = datatype(rmse)
    results[order, header[:order]] = 0

    if vectoroperation == false
        if ttest
            for (index, col) in enumerate(cols)
                pos_b = header[Symbol(string(datanames[col], "_b"))]
                pos_bstd = header[Symbol(string(datanames[col], "_bstd"))]
                pos_t = header[Symbol(string(datanames[col], "_t"))]
                results[order, pos_t] = results[order,pos_b] / results[order,pos_bstd]
            end
        end

        if :aic in criteria || :aicc in criteria
            results[order,header[:aic]] = 2 * results[order,header[:ncoef]] + results[order,header[:nobs]] * log(results[order,header[:sse]] / results[order,header[:nobs]])
        end

        if :aicc in criteria
            results[order,header[:aicc]] = results[order,header[:aic]] + (2(results[order,header[:ncoef]] + 1) * (results[order,header[:ncoef]]+2)) / (results[order,header[:nobs]] - (results[order,header[:ncoef]] + 1 ) - 1)
        end

        if :bic in criteria
            results[order,header[:bic]] = results[order,header[:nobs]] * log.(results[order,header[:rmse]]) + ( results[order,header[:ncoef]] - 1 ) * log.(results[order,header[:nobs]]) + results[order,header[:nobs]] + results[order,header[:nobs]] * log(2π)
        end

        if :r2adj in criteria
            results[order,header[:r2adj]] = 1 - (1 - results[order,header[:r2]]) * ((results[order,header[:nobs]] - 1) / (results[order,header[:nobs]] - results[order,header[:ncoef]]))
        end
            
        results[order,header[:F]] = (results[order,header[:r2]] / (results[order,header[:ncoef]]-1)) / ((1-results[order,header[:r2]]) / (results[order,header[:nobs]] - results[order,header[:ncoef]]))
    end
end

function gsreg_proc_result!(data, results, intercept, outsample, criteria, ttest, vectoroperation, datanames, datatype, header, num_job, num_jobs, ops_by_worker)
    for j = 1:ops_by_worker
        order = (j-1) * num_jobs + num_job
        gsreg_single_proc_result!(data, results, intercept, outsample, criteria, ttest, vectoroperation, datanames, datatype, header, order)
    end
end

function proc!(result::GSRegResult)
    expvars_num = size(result.expvars, 1)
    if result.intercept
        expvars_num = expvars_num-1
    end
    num_operations = 2 ^ expvars_num - 1

    pdata = convert(SharedArray, result.data)
    presults = fill!(SharedArray{result.datatype}(num_operations, length(keys(result.header))),NaN)

    if nprocs() == nworkers()
        for order = 1:num_operations
            gsreg_single_proc_result!(pdata, presults, result.intercept, result.outsample, result.criteria, result.ttest, result.vectoroperation, result.datanames, result.datatype, result.header, order)
        end
    else
        num_workers = nworkers()
        ops_by_worker = div(num_operations, num_workers)
        num_jobs = (num_workers > num_operations)?num_operations:num_workers
        remainder = num_operations - ops_by_worker * num_jobs
        jobs = []
        for num_job = 1:num_jobs
            push!(jobs, @spawnat num_job+1 gsreg_proc_result!(pdata, presults, result.intercept, result.outsample, result.criteria, result.ttest, result.vectoroperation, result.datanames, result.datatype, result.header, num_job, num_jobs, ops_by_worker))
        end

        for job in jobs
            fetch(job)
        end

        if( remainder > 0 )
            for j = 1:remainder
                order = j + ops_by_worker * num_jobs
                gsreg_single_proc_result!(pdata, presults, result.intercept, result.outsample, result.criteria, result.ttest, result.vectoroperation, result.datanames, result.datatype, result.header, order)
            end
        end
    end
    
    result.results = Array(presults)
    presult = nothing
    pdata = nothing

    if result.vectoroperation
        if result.ttest
            for expvar in result.expvars
                pos_b = result.header[Symbol(string(expvar, "_b"))]
                pos_bstd = result.header[Symbol(string(expvar, "_bstd"))]
                pos_t = result.header[Symbol(string(expvar, "_t"))]
                result.results[:,pos_t] = result.results[:,pos_b] ./ result.results[:,pos_bstd]
            end
        end

        if :aic in result.criteria || :aicc in result.criteria
            result.results[:,result.header[:aic]] = 2 * result.results[:,result.header[:ncoef]] + result.results[:,result.header[:nobs]] .* log.(result.results[:,result.header[:sse]] ./ result.results[:,result.header[:nobs]])
        end

        if :aicc in result.criteria
            result.results[:,result.header[:aicc]] = result.results[:,result.header[:aic]] + (2(result.results[:,result.header[:ncoef]] + 1) .* (result.results[:,result.header[:ncoef]]+2)) ./ (result.results[:,result.header[:nobs]] - (result.results[:,result.header[:ncoef]] + 1 ) - 1)
        end

        if :bic in result.criteria
            result.results[:,result.header[:bic]] = result.results[:,result.header[:nobs]] .* log.(result.results[:,result.header[:rmse]]) + ( result.results[:,result.header[:ncoef]] - 1 ) .* log.(result.results[:,result.header[:nobs]]) + result.results[:,result.header[:nobs]] + result.results[:,result.header[:nobs]] .* log(2π)
        end

        if :r2adj in result.criteria
            result.results[:,result.header[:r2adj]] = 1 - (1 - result.results[:,result.header[:r2]]) .* ((result.results[:,result.header[:nobs]] - 1) ./ (result.results[:,result.header[:nobs]] - result.results[:,result.header[:ncoef]]))
        end
            
        result.results[:,result.header[:F]] = (result.results[:,result.header[:r2]] ./ (result.results[:,result.header[:ncoef]]-1)) ./ ((1-result.results[:,result.header[:r2]]) ./ (result.results[:,result.header[:nobs]] - result.results[:,result.header[:ncoef]]))
    end

    # CP must be computed with vector operations
    if :cp in result.criteria
        result.results[:,result.header[:cp]] = (result.results[:,result.header[:nobs]] - maximum(result.results[:,result.header[:ncoef]]) - 2) .* (result.results[:,result.header[:rmse]] ./ minimum(result.results[:,result.header[:rmse]])) - (result.results[:,result.header[:nobs]] - 2 .* result.results[:,result.header[:ncoef]])
    end

    len_criteria = length(result.criteria)
    for criteria in result.criteria
        result.results[:,result.header[:order]] += AVAILABLE_CRITERIA[criteria]["index"] * (1 / len_criteria) * ( (result.results[:,result.header[criteria]] - mean(result.results[:,result.header[criteria]]) ) ./ std(result.results[:,result.header[criteria]]) )
    end

    if result.modelavg
        # usar order para weight
        delta = maximum(result.results[:,result.header[:order]]) - result.results[:,result.header[:order]]
        w1 = exp.(-delta/2)
        result.results[:,result.header[:weight]] = w1./sum(w1)

        result.average = Array{Float64}(1, length(keys(result.header)))

        for expvar in result.expvars
            obs = result.results[:,result.header[Symbol(string(expvar, "_b"))]]
            if result.ttest
                obs = hcat(obs, result.results[:,result.header[Symbol(string(expvar, "_bstd"))]])
            end
            obs = hcat(obs, result.results[:,result.header[:weight]])

            #filter NaN values from selection
            obs = obs[find(x -> !isnan(obs[x,1]), 1:size(obs,1)),:]

            #weight resizing
            obs[:, (result.ttest)?3:2] /= sum(obs[:,(result.ttest)?3:2])

            result.average[result.header[Symbol(string(expvar, "_b"))]] = sum(obs[:, 1] .* obs[:, (result.ttest)?3:2])
            if result.ttest
                result.average[result.header[Symbol(string(expvar, "_bstd"))]] = sum(obs[:, 2] .* obs[:, 3])
            end
        end

        for criteria in [:nobs, :r2adj, :F, :order]
            result.average[result.header[criteria]] = sum(result.results[:, result.header[criteria]] .* result.results[:, result.header[:weight]])
        end
    end

    if result.orderresults
        result.results = sortrows(result.results; lt=(x,y)->isless(x[result.header[:order]],y[result.header[:order]]), rev=true, alg=MergeSort)
        result.bestresult = result.results[1,:]
    else
        max_order = result.results[1,result.header[:order]]
        best_result_index = 1
        for i = 1:num_operations
            if result.results[i,result.header[:order]] > max_order
                max_order = result.results[i,result.header[:order]]
                best_result_index = i
            end
        end
        result.bestresult = result.results[best_result_index,:]
    end
end


function to_string(result::GSRegResult)
    out = ""
    out *= @sprintf("\n")
    out *= @sprintf("══════════════════════════════════════════════════════════════════════════════\n")
    out *= @sprintf("                              Best model results                              \n")
    out *= @sprintf("══════════════════════════════════════════════════════════════════════════════\n")
    out *= @sprintf("                                                                              \n")
    out *= @sprintf("                                     Dependent variable: %s                   \n", result.depvar)
    out *= @sprintf("                                     ─────────────────────────────────────────\n")
    out *= @sprintf("                                                                              \n")
    out *= @sprintf(" Selected covariates                 Coef.")
    if result.ttest
        out *= @sprintf("        Std.         t-test")
    end
    out *= @sprintf("\n")
    out *= @sprintf("──────────────────────────────────────────────────────────────────────────────\n")

    cols = get_selected_cols(Int64(result.bestresult[result.header[:index]]))

    data_cols_num = size(result.data, 2)
    if result.intercept
        append!(cols, data_cols_num)
    end

    for pos in cols
        varname = result.datanames[pos]
        out *= @sprintf(" %-35s", varname)
        out *= @sprintf(" %-10f", result.bestresult[result.header[Symbol(string(varname, "_b"))]])
        if result.ttest
            out *= @sprintf("   %-10f", result.bestresult[result.header[Symbol(string(varname, "_bstd"))]])
            out *= @sprintf("   %-10f", result.bestresult[result.header[Symbol(string(varname, "_t"))]])
        end
        out *= @sprintf("\n")
    end
    
    out *= @sprintf("──────────────────────────────────────────────────────────────────────────────\n")
    out *= @sprintf(" Observations                        %-10d\n", result.bestresult[result.header[:nobs]])
    out *= @sprintf(" Adjusted R²                         %-10f\n", result.bestresult[result.header[:r2adj]])
    out *= @sprintf(" F-statistic                         %-10f\n", result.bestresult[result.header[:F]])
    for criteria in result.criteria
        if AVAILABLE_CRITERIA[criteria]["verbose_show"]
    out *= @sprintf(" %-30s      %-10f\n", AVAILABLE_CRITERIA[criteria]["verbose_title"], result.bestresult[result.header[criteria]])
        end
    end

    if !result.modelavg
    out *= @sprintf("──────────────────────────────────────────────────────────────────────────────\n")
    end

    if result.modelavg
    out *= @sprintf("══════════════════════════════════════════════════════════════════════════════\n")
    out *= @sprintf("                            Model averaging results                           \n")
    out *= @sprintf("══════════════════════════════════════════════════════════════════════════════\n")
    out *= @sprintf("                                                                              \n")
    out *= @sprintf("                                     Dependent variable: %s                   \n", result.depvar)
    out *= @sprintf("                                     ─────────────────────────────────────────\n")
    out *= @sprintf("                                                                              \n")
    out *= @sprintf(" Covariates                          Coef.")
    if result.ttest
        out *= @sprintf("        Std.         t-test")
    end
    out *= @sprintf("\n")
    out *= @sprintf("──────────────────────────────────────────────────────────────────────────────\n")
    end

    for varname in result.expvars
        out *= @sprintf(" %-35s", varname)
        out *= @sprintf(" %-10f", result.average[result.header[Symbol(string(varname, "_b"))]])
        if result.ttest
            out *= @sprintf("   %-10f", result.average[result.header[Symbol(string(varname, "_bstd"))]])
            out *= @sprintf("   %-10f", result.average[result.header[Symbol(string(varname, "_b"))]] / result.average[result.header[Symbol(string(varname, "_bstd"))]])
        end
        out *= @sprintf("\n")
    end
    out *= @sprintf("\n")
    out *= @sprintf("──────────────────────────────────────────────────────────────────────────────\n")
    out *= @sprintf(" Observations                        %-10f\n", result.average[result.header[:nobs]])
    out *= @sprintf(" Adjusted R²                         %-10f\n", result.average[result.header[:r2adj]])
    out *= @sprintf(" F-statistic                         %-10f\n", result.average[result.header[:F]])
    out *= @sprintf(" Combined criteria                   %-10f\n", result.average[result.header[:order]])
    out *= @sprintf("──────────────────────────────────────────────────────────────────────────────\n")
    return out
end

Base.show(io::IO, result::GSRegResult) = print(to_string(result))
