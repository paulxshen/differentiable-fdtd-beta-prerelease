using UnPack, LinearAlgebra, Random, LazyStack
using Zygote
using Zygote: ignore, Buffer
using BSON: @save, @load

# using Jello
include("startup.jl")
include("../Porcupine.jl/src/del.jl")
include("../Jello.jl/src/mask.jl")
include("../ArrayPadding.jl/src/pad.jl")
include("boundaries.jl")
include("sources.jl")
include("monitors.jl")
include("utils.jl")
include("fdtd.jl")

using Images, CairoMakie
include("plotstep.jl")

F = Float32
Random.seed!(1)

train = true
# train = false
nepochs = 2
T = 10.0f0 # simulation duration in periods
opt = Adam(0.1)
λ = 1.28f0 # wavelength in microns
dx = 1.0f0 / 32 # pixel resolution in wavelengths
lmin = 0.2f0 / λ # minimum feature length in design region in wavelengths
Courant = 0.5f0 # Courant number

# loads Google's Ceviche challenge
_dx = λ * dx
@unpack base, design_start, design_sz, l = load("bend0", _dx)
L = size(base) .* dx # domain dimensions [wavelength]
l = l ./ λ
sz = size(base)
tspan = (0.0f0, T)
dt = dx * Courant
saveat = 1 / 16.0f0

model = Mask(design_sz, lmin / dx) # parameterized binary mask for design region
model0 = deepcopy(model)
polarization = :TMz
ϵ1 = 2.25f0
ϵ2 = 12.25f0

boundaries = [] # unspecified boundaries default to PML
monitors = [Monitor([0.0f0, l], [:Ez, :Hy]), Monitor([l, 0.0f0], [:Ez, :Hx,])]
sources = [GaussianBeam(t -> cos(F(2π) * t), 0.1f0 / λ, (0.0f0, l), 1; Jz=1)]
@unpack geometry_padding, field_padding, source_effects, monitor_configs, save_idxs, fields =
    setup(boundaries, sources, monitors, L, dx, polarization; F)

static_geometry = (; μ=ones(F, sz), σ=zeros(F, sz), σm=zeros(F, sz))
function make_geometry(model, base, start, static_geometry)
    b = place(base, model(), start)
    ϵ = ϵ2 * b + ϵ1 * (1 .- b)
    @unpack μ, σ, σm = static_geometry
    geometry = apply(geometry_padding; ϵ, μ, σ, σm)
end
p = make_geometry(model, base, design_start, static_geometry)


∇ = Del([dx, dx])
function step(u, p, t)
    ϵ, μ, σ, σm = p |> a -> [[a] for a = a]
    Ez, Hx, Hy, Jz0 = u
    Jz, = apply(source_effects, t; Jz=Jz0)

    # first update E
    H_ = apply(field_padding, ; Hx=PaddedArray(Hx), Hy=PaddedArray(Hy))
    E = [Ez]
    J = [Jz]
    dEdt = (∇ × H_ - σ * E - J) / ϵ
    E += dEdt * dt
    Ez, = E

    # then update H
    E_ = apply(field_padding, ; Ez=PaddedArray(Ez))
    H = [Hx, Hy]
    dHdt = -(∇ × E_ + σm * H) / μ
    H += dHdt * dt
    Hx, Hy = H

    [Ez, Hx, Hy, Jz0]
end

dsaveat = round(Int, saveat / dt)
function loss(model; withsol=false, callback=nothing)
    p = make_geometry(model, base, design_start, static_geometry)
    u = collect(fields)
    # t = 0:dt:T
    # sol = Buffer([u], ceil(Int, length(t) / dsaveat))
    t = 0:(dt*dsaveat):T
    sol = [
        begin

            for i = 1:dsaveat
                u = step(u, p, t)
                t += dt
            end
            u
        end
        for t = t
    ]

    # # sol = reduce(hcat, reduce.(vcat, values.(sol)))
    # sol = lazystack(Array.(copy(sol)))
    t = (round(Int, (T - 1) / saveat):round(Int, T / saveat)) .+ 1
    Ez, Hx = get(sol, monitor_configs[2], t)

    l = 1mean(Ez .* Hx)
    withsol ? (l, sol) : l
end


if train
    opt_state = Flux.setup(opt, model)

    # fig = Figure()
    # heatmap(fig[1, 1], m(0), axis=(; title="start of training"))
    for i = 1:nepochs
        @time begin

            global dldm
            l, (dldm,) = withgradient(loss, model,)
            # (l, sol), (dldm,) = withgradient(loss, model,)
            Flux.update!(opt_state, model, dldm)
            println("$i $l")
        end
    end
    # heatmap(fig[1, 2], m(0), axis=(; title="end of training"))
end
@showtime l, sol = loss(model; withsol=true,)

frameat = 1 / 4
t = 0:frameat:T
i = round.(Int, t ./ saveat) .+ 1
framerate = round(Int, 1 / frameat)
fig = Figure()
record(fig, "bend.gif", collect(zip(i, t)); framerate) do (i, t)
    ax = Axis(fig[1, 1]; title="t = $t\nEz")
    u = sol[i]
    # u = sol[:, :, :, i]
    plotstep(u, p, t; ax)
end

using CairoMakie
using CairoMakie: Axis
# t = 0.0f0:dt:T
t = range(0, T, length=size(sol)[end])
fig = Figure()
for i = 1:2
    ax = Axis(fig[i, 1], title="")
    E, H = get(sol, monitor_configs[i],)
    #  = if i == 1
    #     m.Ez, m.Hy
    # elseif i == 2
    #     m.Ez, m.Hx
    # end
    lines!(ax, t, E)
    lines!(ax, t, H)
    lines!(ax, t, H .* E)
end
display(fig)