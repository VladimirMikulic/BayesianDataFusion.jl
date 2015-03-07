export pred

function pred(r::Relation, probe_vec::DataFrame, F)
  if ! hasFeatures(r)
    return udot(r, probe_vec) + r.model.mean_value
  end
  return udot(r, probe_vec) + F * r.model.beta + r.model.mean_value
end

function pred(r::Relation)
  udot(r, r.data.df) + (hasFeatures(r) ? r.temp.linear_values : r.model.mean_value)
end

## computes predictions sum(u1 .* u2 .* ... .* uR, 2) for relation r
function udot(r::Relation, probe_vec::DataFrame)
  U = r.entities[1].model.sample[probe_vec[:,1],:]
  for i in 2:length(r.entities)
    U .*= r.entities[i].model.sample[probe_vec[:,i],:]
  end
  return vec(sum(U, 2))
end

function makeClamped(x, clamp::Vector{Float64})
  x2 = copy(x)
  x2[x2 .< clamp[1]] = clamp[1]
  x2[x2 .> clamp[2]] = clamp[2]
  return x2
end

function ConditionalNormalWishart(U::Matrix{Float64}, mu::Vector{Float64}, kappa::Real, Tinv::Matrix{Float64}, nu::Real)
  N  = size(U, 1)
  Ū  = mean(U,1)
  cU = U .- Ū
  S  = cU' * cU
  Ū  = Ū'

  mu_c = (kappa*mu + N*Ū) / (kappa + N)
  kappa_c = kappa + N
  T_c = inv( Tinv + S + (kappa * N)/(kappa + N) * (mu - Ū) * (mu - Ū)' )
  nu_c = nu + N

  NormalWishart(vec(mu_c), kappa_c, T_c, nu_c)
end

function sample_alpha(alpha_lambda0::Float64, alpha_nu0::Float64, err::Vector{Float64})
  Λ  = alpha_lambda0 * eye(1)
  n  = length(err)
  SW = inv(inv(Λ) + err' * err)
  return rand(Wishart(alpha_nu0 + n, SW))[1]
end

function sample_lambda_beta(β::Matrix{Float64}, Lambda_u::Matrix{Float64}, ν::Float64, μ::Float64)
  νx = ν + size(β, 1) * size(β, 2)
  μx = μ * νx / (ν + μ * trace( (β'*β) * Lambda_u) )
  b  = νx / 2
  c  = 2*μx / νx
  return rand(Gamma(b, c))
end

function grab_col{Tv,Ti}(A::SparseMatrixCSC{Tv,Ti}, col::Integer)
  r = A.colptr[col]:A.colptr[col+1]-1
  A.rowval[r], A.nzval[r]
end

function sample_user_old(uu, Au::IndexedDF, mode::Int, mean_rating, sample_m, alpha, mu_u, Lambda_u, num_latent)
  #ff, v = grab_col(Au, uu)
  df = getData(Au, mode, uu)
  ff = df[:, mode == 1 ? 2 : 1]
  v  = array( df[:, end] )

  rr = v - mean_rating
  MM = sample_m[ff,:]

  covar = inv(Lambda_u + alpha * MM'*MM)
  mu    = covar * (alpha * MM'*rr + Lambda_u * mu_u)

  # Sample from normal distribution
  chol(covar)' * randn(num_latent) + mu
end

function sample_user2(s::Entity, i::Int, mu_si, modes::Vector{Int64}, modes_other::Vector{Vector{Int64}})
  Lambda_si = copy(s.model.Lambda)
  mux       = s.model.Lambda * mu_si

  for r = 1:length(s.relations)
    rel = s.relations[r]
    df  = getData(rel.data, modes[r], i)
    rr  = array( df[:,end] ) - (hasFeatures(rel) ? rel.temp.linear_values[getI(rel.data, modes[r], i)] : rel.model.mean_value)
    modes_o1 = modes_other[r][1]
    modes_o2 = modes_other[r][2:end]

    MM = rel.entities[modes_o1].model.sample[ df[:,modes_o1], : ]
    for j = modes_o2
      MM .*= rel.entities[j].model.sample[ df[:,j], : ]
    end
    Lambda_si += rel.model.alpha * MM' * MM
    mux       += rel.model.alpha * MM' * rr
  end
  covar = inv(Lambda_si)
  mu    = covar * mux

  # Sample from normal distribution
  chol(covar)' * randn(length(mu)) + mu
end

function sample_beta(F, sample_u_c, Lambda_u, lambda_beta)
  N, D = size(sample_u_c)
  numF = size(F, 2)
  
  mv = MultivariateNormal(zeros(D), inv(Lambda_u) )
  Ft_y = F' * (sample_u_c + rand(mv, N)') + sqrt(lambda_beta) * rand(mv, numF)'
  
  # executed in parallel
  beta_list = pmap( d -> ridge_solve(F, Ft_y[:,d], lambda_beta), 1:D )
  beta = zeros(numF, D)
  for d = 1:D
    beta[:,d] = beta_list[d]
  end
  return beta, Ft_y
end

function sample_beta_rel(r::Relation)
  N, F = size(r.F)
  alpha  = r.model.alpha
  lambda = r.model.lambda_beta

  res  = getValues(r.data) - udot(r, r.data.df) - r.model.mean_value
  aFt_y = alpha * (r.F' * (res + alpha^(-0.5) * randn(N))) + sqrt(lambda) * randn(F)

  if isdefined(r.temp, :FF)
    ## using FF to compute beta_r
    K = alpha * r.temp.FF + lambda * speye(F)
    return K \ aFt_y
  else
    error("conjugate gradient unimplemented for sampling relation beta")
  end
end
