module RMesh
export RectMesh,
       MeshCoord, mesh_coord,
       lesser_side_face_perp_to_axis, greater_side_face_perp_to_axis

using Common
import Mesh, Mesh.FENum, Mesh.NBSideNum, Mesh.FERelFace, Mesh.AbstractMesh, Mesh.NBSideInclusions, Mesh.fe_face
import Poly, Poly.Monomial, Poly.VectorMonomial
import Cubature.hcubature

# type of a single logical mesh coordinates component (column or row or stack, etc)
typealias MeshCoord Uint64
mesh_coord(i::Integer) = convert(MeshCoord, i)


type NBSideGeom
  perp_axis::Dim
  mesh_coords::Array{MeshCoord, 1}
end

const default_integration_rel_err = 10e-10
const default_integration_abs_err = 10e-10

type RectMesh <: AbstractMesh

  space_dim::Dim

  # Mesh coordinate ranges in R^d defining the boundaries of the mesh.
  min_bounds::Array{R,1}
  max_bounds::Array{R,1}

  # Logical dimensions of the mesh in discrete mesh axis coordinates,
  # with directions corresponding to the coordinate axes (cols, rows,...).
  mesh_ldims::Array{MeshCoord,1}

  # actual dimensions of any single finite element
  fe_dims::Array{R,1}
  fe_dims_wo_dim::Array{Array{R,1},1}

  cumprods_mesh_ldims::Array{FENum,1}

  cumprods_nb_side_mesh_ldims_by_perp_axis::Array{Array{NBSideNum,1},1}

  first_nb_side_nums_by_perp_axis::Array{NBSideNum,1}

  num_fes::FENum
  num_nb_sides::NBSideNum
  num_side_faces_per_fe::Uint

  fe_diameter_inv::R

  one_mon::Monomial


  # integration support members
  intgd_args_work_array::Vector{R}
  ref_fe_min_bounds::Vector{R}
  ref_fe_min_bounds_short::Vector{R}
  integration_rel_err::R
  integration_abs_err::R

  function RectMesh(min_bounds::Array{R,1},
                    max_bounds::Array{R,1},
                    mesh_ldims::Array{MeshCoord,1},
                    integration_rel_err::R,
                    integration_abs_err::R)
    const space_dim = length(min_bounds) | uint
    assert(length(max_bounds) == space_dim, "min and max bound lengths should match")
    assert(length(mesh_ldims) == space_dim, "logical dimensions length does not match physical bounds length")

    const fe_dims = make_fe_dims(min_bounds, max_bounds, mesh_ldims)
    const fe_dims_wo_dim = make_fe_dims_with_drops(fe_dims)

    const cumprods_mesh_ldims = cumprod(mesh_ldims)
    const cumprods_nb_side_mesh_ldims = make_cumprods_nb_side_mesh_ldims_by_perp_axis(mesh_ldims)

    const nb_side_counts_by_perp_axis = map(last, cumprods_nb_side_mesh_ldims)
    const first_nb_side_nums_by_perp_axis = cumsum(vcat(1, nb_side_counts_by_perp_axis[1:space_dim-1]))

    const num_fes = last(cumprods_mesh_ldims)
    const num_nb_sides = sum(nb_side_counts_by_perp_axis)
    const num_side_faces_per_fe = 2 * space_dim

    const fe_diameter_inv = 1/sqrt(dot(fe_dims, fe_dims))

    new(dim(space_dim),
        min_bounds,
        max_bounds,
        mesh_ldims,
        fe_dims,
        fe_dims_wo_dim,
        cumprods_mesh_ldims,
        cumprods_nb_side_mesh_ldims,
        first_nb_side_nums_by_perp_axis,
        num_fes,
        num_nb_sides,
        num_side_faces_per_fe,
        fe_diameter_inv,
        Monomial(zeros(Deg,space_dim)),
        Array(R, space_dim), # integrand args work array
        zeros(R, space_dim), # ref fe min bounds
        zeros(R, space_dim-1), # ref fe min bounds, short
        integration_rel_err,
        integration_abs_err)
  end
end # type RectMesh

RectMesh(min_bounds::Array{R,1},
         max_bounds::Array{R,1},
         mesh_ldims::Array{MeshCoord,1}) =
  RectMesh(min_bounds, max_bounds, mesh_ldims, default_integration_rel_err, default_integration_abs_err)

# Auxiliary construction functions

function make_fe_dims(min_bounds::Array{R,1}, max_bounds::Array{R,1}, mesh_ldims::Array{MeshCoord,1})
  const space_dim = length(min_bounds)
  const dims = Array(R, space_dim)
  for i=1:space_dim
    const bounds_diff = max_bounds[i] - min_bounds[i]
    const ldim_i = mesh_ldims[i]
    assert(bounds_diff > zeroR, "improper mesh bounds")
    assert(ldim_i > 0, "non-positive logical mesh dimension")
    dims[i] = bounds_diff/ldim_i
  end
  dims
end

function make_fe_dims_with_drops(fe_dims::Array{R,1})
  const d = length(fe_dims)
  const dims_wo_dim = Array(Array{R,1}, d)
  for r=1:d
    dims_wo_dim[r] = fe_dims[[1:r-1,r+1:d]]
  end
  dims_wo_dim
end

function make_cumprods_nb_side_mesh_ldims_by_perp_axis(fe_mesh_ldims::Array{MeshCoord,1})
  const space_dim = length(fe_mesh_ldims)
  [ [make_cumprod_nb_side_mesh_ldims_to(r, perp_axis, fe_mesh_ldims) for r=1:space_dim]
    for perp_axis=1:space_dim ]
end

function make_cumprod_nb_side_mesh_ldims_to(r::Int, perp_axis::Int, fe_mesh_ldims::Array{MeshCoord,1})
  prod = one(NBSideNum)
  for i=1:r
    prod *= (i != perp_axis ? fe_mesh_ldims[i] : fe_mesh_ldims[i]-1)
  end
  prod::NBSideNum
end


##############################################
## Implement functions required of all meshes.

import Mesh.space_dim
space_dim(mesh::RectMesh) = mesh.space_dim

import Mesh.one_mon
one_mon(mesh::RectMesh) = mesh.one_mon

import Mesh.num_fes
num_fes(mesh::RectMesh) = mesh.num_fes

import Mesh.num_nb_sides
num_nb_sides(mesh::RectMesh) = mesh.num_nb_sides

import Mesh.num_side_faces_per_fe
num_side_faces_per_fe(mesh::RectMesh) = mesh.num_side_faces_per_fe

import Mesh.dependent_dim_for_nb_side
dependent_dim_for_nb_side(i::NBSideNum, mesh::RectMesh) = perp_axis_for_nb_side(i, mesh)

import Mesh.dependent_dim_for_ref_side_face
dependent_dim_for_ref_side_face(side_face::FERelFace, mesh::RectMesh) = side_face_perp_axis(side_face)

import Mesh.fe_inclusions_of_nb_side!
function fe_inclusions_of_nb_side!(n::NBSideNum, mesh::RectMesh, incls::NBSideInclusions)
  const sgeom = nb_side_geom(n, mesh)
  const a = sgeom.perp_axis
  const lesser_fe = fe_with_mesh_coords(sgeom.mesh_coords, mesh)
  const greater_fe =  lesser_fe + (a == 1 ? 1 : mesh.cumprods_mesh_ldims[a-1])
  incls.fe1 = lesser_fe
  incls.face_in_fe1 = greater_side_face_perp_to_axis(a)
  incls.fe2 = greater_fe
  incls.face_in_fe2 = lesser_side_face_perp_to_axis(a)
  incls.nb_side_num = n
end

import Mesh.is_boundary_side
function is_boundary_side(fe::FENum, side_face::FERelFace, mesh::RectMesh)
  const a = side_face_perp_axis(side_face)
  const coord_a = fe_mesh_coord(a, fe, mesh)
  const is_lesser_side = side_face_is_lesser_on_perp_axis(side_face)
  coord_a == 1 && is_lesser_side || coord_a == mesh.mesh_ldims[a] && !is_lesser_side
end

import Mesh.fe_diameter_inv
fe_diameter_inv(fe::FENum, mesh::RectMesh) =
  mesh.fe_diameter_inv


# integration functions

# Local Origins in Integration Functions
# --------------------------------------
# For each face in the mesh, the mesh must assign a local origin to be used to
# evaluate face-local functions. In this implementation, for each face F we choose
# the coordinate minimums vertex for the face, whose r^th coordinate is
#   o_r(F) = min {x_r | x in F}
# One consequence of this for our implementation, which employs coordinate-aligned
# sides, is useful in the integral methods below.  Which is, that for any function
# defined locally on a side S perpendicular to axis r, the r^th component of every
# input from S to the local function will be 0, and all other components will be
# the same as for the finite element relative origin.


import Mesh.integral_face_rel_on_face
function integral_face_rel_on_face(mon::Monomial, face::FERelFace, mesh::RectMesh)
  if face == Mesh.interior_face
    Poly.integral_on_rect_at_origin(mon, mesh.fe_dims)
  else
    const a = side_face_perp_axis(face)
    dim_reduced_intgd = Poly.reduce_dim_by_fixing(a, zeroR, mon)
    Poly.integral_on_rect_at_origin(dim_reduced_intgd, mesh.fe_dims_wo_dim[a])
  end
end

import Mesh.integral_global_x_face_rel_on_fe_face
function integral_global_x_face_rel_on_fe_face(f::Function, mon::Monomial, fe::FENum, face::FERelFace, mesh::RectMesh)
  const d = mesh.space_dim
  const fe_local_origin = fe_coords(fe, mesh)
  const fe_x = mesh.intgd_args_work_array
  if face == Mesh.interior_face
    function ref_intgd(x::Vector{R})
      for i=1:d
        fe_x[i] = fe_local_origin[i] + x[i]
      end
      f(fe_x) * Poly.monomial_value(mon, x)
    end
    hcubature(ref_intgd, mesh.ref_fe_min_bounds, mesh.fe_dims, mesh.integration_rel_err, mesh.integration_abs_err)[1]
  else # side face
    const a = side_face_perp_axis(face)
    const a_coord_of_fe_side = fe_local_origin[a] + (side_face_is_lesser_on_perp_axis(face) ? zeroR : mesh.fe_dims[a])
    const mon_dim_reduced_poly = Poly.reduce_dim_by_fixing(a, zeroR, mon)
    function ref_intgd(x::Vector{R}) # x has d-1 components
      for i=1:a-1
        fe_x[i] = fe_local_origin[i] + x[i]
      end
      fe_x[a] = a_coord_of_fe_side
      for i=a+1:d
        fe_x[i] = fe_local_origin[i] + x[i-1]
      end
      f(fe_x) * Poly.polynomial_value(mon_dim_reduced_poly, x)
    end
    hcubature(ref_intgd, mesh.ref_fe_min_bounds_short, mesh.fe_dims_wo_dim[a], mesh.integration_rel_err, mesh.integration_abs_err)[1]
  end
end

# Integrate a side-relative monomial m on its side face vs. an fe-relative vector monomial dotted with the outward normal.
import Mesh.integral_side_rel_x_fe_rel_vs_outward_normal_on_side
function integral_side_rel_x_fe_rel_vs_outward_normal_on_side(m::Monomial, q::VectorMonomial, side_face::FERelFace, mesh::RectMesh)
  const a = side_face_perp_axis(side_face)
  const qa = q[a]
  if qa == zeroR
    zeroR
  else
    const is_lesser_side = side_face_is_lesser_on_perp_axis(side_face)
    const side_fe_rel_a_coord = is_lesser_side ? zeroR : mesh.fe_dims[a]
    const qa_dim_red = Poly.reduce_dim_by_fixing(a, side_fe_rel_a_coord, qa)
    const m_dim_red = Poly.reduce_dim_by_fixing(a, zeroR, m)
    const int_m_qa = Poly.integral_on_rect_at_origin(m_dim_red * qa_dim_red, mesh.fe_dims_wo_dim[a])
    is_lesser_side ? -int_m_qa : int_m_qa
  end
end

import Mesh.integral_fe_rel_x_side_rel_on_side
function integral_fe_rel_x_side_rel_on_side(fe_mon::Monomial, side_mon::Monomial, side_face::FERelFace, mesh::RectMesh)
  const a = side_face_perp_axis(side_face)
  const is_lesser_side = side_face_is_lesser_on_perp_axis(side_face)
  const side_fe_rel_a_coord = is_lesser_side ? zeroR : mesh.fe_dims[a]
  const fe_mon_dim_red = Poly.reduce_dim_by_fixing(a, side_fe_rel_a_coord, fe_mon)
  const side_mon_dim_red = Poly.reduce_dim_by_fixing(a, zeroR, side_mon)
  Poly.integral_on_rect_at_origin(fe_mon_dim_red * side_mon_dim_red, mesh.fe_dims_wo_dim[a])
end

##
##############################################


# Returns one coordinate of a finite element in the main fe/interiors mesh.
function fe_mesh_coord(r::Dim, fe::FENum, mesh::RectMesh)
  # The r^th coordinate of side n is
  #   π(r,n) = ((n − 1) mod (k_1 ··· k_r)) \ (k_1 ··· k_(r−1)) + 1
  # where k_i is the i^th component of the mesh dimensions.
  # See Rectangular_Meshes.pdf document for the derivation.
  assert(r <= mesh.space_dim, "coordinate number out of range")
  assert(fe <= mesh.num_fes, "finite element number out of range")
  div(mod(fe-1, mesh.cumprods_mesh_ldims[r]), r==1 ? 1 : mesh.cumprods_mesh_ldims[r-1]) + 1
end

function fe_mesh_coords(fe::FENum, mesh::RectMesh)
  const d = mesh.space_dim
  const coords = Array(R, d)
  for r=dim(1):dim(d)
    coords[r] = fe_mesh_coord(r, fe, mesh)
  end
  coords
end

# Converts finite element/interior coords in the main mesh to a finite element/interior number.
function fe_with_mesh_coords(coords::Array{MeshCoord,1}, mesh::RectMesh)
  # The finite element (or interior) number for given mesh coordinates (c_1,...,c_d) is
  #   i_#(c_1,...,c_d) = sum_{i=1..d} { (c_i - 1) prod_{l=1..i-1} k_l } + 1
  #                    = c_1 + sum_{i=2..d} { (c_i - 1) prod_{l=1..i-1} k_l }
  # where k_l is the l^th component of the mesh dimensions.
  sum = coords[1]
  for i=2:mesh.space_dim
    sum += (coords[i]-1) * mesh.cumprods_mesh_ldims[i-1]
  end
  sum
end

# Fill the passed array with the coordinates of the finite element corner with range-minimum coordinates.
function fe_coords!(fe::FENum, mesh::RectMesh, coords::Vector{R})
  const d = mesh.space_dim
  for r=1:d
    coords[r] = mesh.min_bounds[r] + (fe_mesh_coord(dim(r), fe, mesh) - 1) * mesh.fe_dims[r]
  end
  coords
end

# Functional variant of the above.
function fe_coords(fe::FENum, mesh::RectMesh)
  const d = mesh.space_dim
  const coords = Array(R, d)
  fe_coords!(fe, mesh, coords)
  coords
end


# side-related functions

# Find the axis which is perpendicular to the given side face.
side_face_perp_axis(side::FERelFace) = dim(div(side-1, 2) + 1)

# Determine whether a side face is the one with lesser axis value along its perpendicular axis.
side_face_is_lesser_on_perp_axis(side::FERelFace) = mod(side-1, 2) == 0

# Returns the side face with lesser axis value along the indicated axis.
lesser_side_face_perp_to_axis(a::Dim) = fe_face(2*a - 1)

# Returns the side face with greater axis value along the indicated axis.
greater_side_face_perp_to_axis(a::Dim) = fe_face(2*a)


# Finds the perpendicular axis for a given non-boundary side in the mesh.
function perp_axis_for_nb_side(n::NBSideNum, mesh::RectMesh)
  assert(0 < n <= mesh.num_nb_sides, "non-boundary side number out of range")
  for i=mesh.space_dim:-1:1
    if n >= mesh.first_nb_side_nums_by_perp_axis[i]
      return dim(i)
    end
  end
  error("cannot find perpendicular axis for non-boundary side number $n")
end

# Returns the geometric information for a non-boundary side in the mesh, which identifies the perpendicular
# axis for the side (and thus its orientation-specific side mesh), together with its coordinates in its
# orientation-specific mesh.
function nb_side_geom(n::NBSideNum, mesh::RectMesh)
  # The r^th coordinate of side n in the mesh of sides having the same orientation is
  #   π_s(r,n) = ((n − s_a(n)) mod Prod_{i=1..r} k_{a(n),i}) \ (Prod_{i=1..r-1} k_{a(n),i}) + 1    (r = 1,...,d)
  # where
  #   s_j is the number of the first side in the nb-side enumeration perpendicular to axis j
  #   a(n) is the axis number to which side n is perpendicular
  #   k_{j,i} is the i^th component of the dimensions of the mesh of sides perpendicular to axis j
  # See Rectangular_Meshes.pdf document for the derivation.
  const a = perp_axis_for_nb_side(n, mesh)
  const coords = Array(MeshCoord, mesh.space_dim)
  const side_mesh_rel_ix = n - mesh.first_nb_side_nums_by_perp_axis[a]
  const cumprods_side_mesh_ldims = mesh.cumprods_nb_side_mesh_ldims_by_perp_axis[a]
  # first coord is a special case because of the empty product (improper range) in the denominator
  coords[1] = mod(side_mesh_rel_ix, cumprods_side_mesh_ldims[1]) + 1
  for r=2:mesh.space_dim
    coords[r] = div(mod(side_mesh_rel_ix, cumprods_side_mesh_ldims[r]),
                    cumprods_side_mesh_ldims[r-1]) + 1
  end
  NBSideGeom(a, coords)
end

end # end of module