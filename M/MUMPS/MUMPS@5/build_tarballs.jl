using BinaryBuilder, Pkg
using Base.BinaryPlatforms
const YGGDRASIL_DIR = "../../.."
include(joinpath(YGGDRASIL_DIR, "platforms", "mpi.jl"))

name = "MUMPS"
version = v"5.5.1"

sources = [
  ArchiveSource("https://graal.ens-lyon.fr/MUMPS/MUMPS_$(version).tar.gz",
                "1abff294fa47ee4cfd50dfd5c595942b72ebfcedce08142a75a99ab35014fa15"),
  DirectorySource("./bundled")
]

# Bash recipe for building across all platforms
script = raw"""
mkdir -p ${libdir}
cd $WORKSPACE/srcdir/MUMPS*
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/pord.patch
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/Makefile.patch

makefile="Makefile.G95.PAR"
cp Make.inc/${makefile} Makefile.inc

# Add `-fallow-argument-mismatch` if supported
: >empty.f
if gfortran -c -fallow-argument-mismatch empty.f >/dev/null 2>&1; then
    FFLAGS=("-fallow-argument-mismatch")
fi
rm -f empty.*

if [[ "${target}" == *apple* ]]; then
    SONAME="-install_name"
else
    SONAME="-soname"
fi

# We need to specify the MPI libraries explicitly because the
# CMakeLists.txt doesn't properly add them when linking
MPI_SETTINGS=(-DMPI_BASE_DIR="${prefix}")
MPILIBS=()
if grep -q MSMPI_VER "${includedir}/mpi.h"; then
    MPI_SETTINGS+=(-DMPI_GUESS_LIBRARY_NAME=MSMPI)
    MPILIBS=(-lmsmpifec64 -lmsmpi64)
elif grep -q MPICH "${includedir}/mpi.h"; then
    MPILIBS=(-lmpifort -lmpi)
elif grep -q MPItrampoline "${includedir}/mpi.h"; then
    MPILIBS=(-lmpitrampoline)
elif grep -q OMPI_MAJOR_VERSION "${includedir}/mpi.h"; then
    MPILIBS=(-lmpi_usempif08 -lmpi_usempi_ignore_tkr -lmpi_mpifh -lmpi)
fi

# Override MPItrampoline's built-in compiler paths
export MPITRAMPOLINE_CC=cc
export MPITRAMPOLINE_CXX=c++
export MPITRAMPOLINE_FC=gfortran

make_args+=(OPTF=-O3 \
            CDEFS=-DAdd_ \
            LMETISDIR="${libdir}" \
            IMETIS="-I${includedir}" \
            LMETIS="-L${libdir} -lparmetis -lmetis" \
            ORDERINGSF="-Dpord -Dparmetis" \
            LIBEXT_SHARED=".${dlext}" \
            SONAME="${SONAME}" \
            CC="mpicc -fPIC ${CFLAGS[@]}" \
            FC="mpifort -fPIC ${FFLAGS[@]}" \
            FL="mpifort -fPIC" \
            RANLIB="echo" \
            LAPACK="-L${libdir} -lopenblas"
            SCALAP="-L${libdir} -lscalapack32" \
            INCPAR="-I${includedir}" \
            LIBPAR="-L${libdir} -lscalapack32 -lopenblas ${MPILIBS[*]}" \
            LIBBLAS="-L${libdir} -lopenblas")

# Options for SCOTCH
# LSCOTCHDIR=${prefix}
# ISCOTCH="-I${includedir}"
# LSCOTCH="-L${libdir} -lesmumps -lscotch -lscotcherr"
# ORDERINGSF="-Dpord -Dparmetis -Dscotch"

make -j${nproc} allshared "${make_args[@]}"

cp include/*.h ${includedir}
cp lib/*.${dlext} ${libdir}
"""

augment_platform_block = """
    using Base.BinaryPlatforms
    $(MPI.augment)
    augment_platform!(platform::Platform) = augment_mpi!(platform)
"""

platforms = filter!(p -> !Sys.iswindows(p), supported_platforms())
platforms = expand_gfortran_versions(platforms)
platforms, platform_dependencies = MPI.augment_platforms(platforms)

# Avoid platforms where the MPI implementation isn't supported
# OpenMPI
platforms = filter(p -> !(p["mpi"] == "openmpi" && arch(p) == "armv6l" && libc(p) == "glibc"), platforms)
# MPItrampoline
platforms = filter(p -> !(p["mpi"] == "mpitrampoline" && libc(p) == "musl"), platforms)
platforms = filter(p -> !(p["mpi"] == "mpitrampoline" && Sys.isfreebsd(p)), platforms)

# SCALAPACK32 is not compiled for:
# - aarch64-linux-musl-libgfortran4-mpi+mpich
# - aarch64-linux-musl-libgfortran4-mpi+openmpi
platforms = filter(p -> !(arch(p) == "aarch64" && Sys.islinux(p) && libc(p) == "musl" && libgfortran_version(p) == v"4" && p["mpi"] == "mpich"), platforms)
platforms = filter(p -> !(arch(p) == "aarch64" && Sys.islinux(p) && libc(p) == "musl" && libgfortran_version(p) == v"4" && p["mpi"] == "openmpi"), platforms)

# The products that we will ensure are always built
products = [
    LibraryProduct("libsmumps", :libsmumps),
    LibraryProduct("libdmumps", :libdmumps),
    LibraryProduct("libcmumps", :libcmumps),
    LibraryProduct("libzmumps", :libzmumps),
    LibraryProduct("libmumps_common", :libmumps_common),
]

# Dependencies that must be installed before this package can be built
dependencies = [
    Dependency(PackageSpec(name="CompilerSupportLibraries_jll", uuid="e66e0078-7015-5450-92f7-15fbd957f2ae")),
    Dependency(PackageSpec(name="METIS_jll", uuid="d00139f3-1899-568f-a2f0-47f597d42d70")),
    Dependency(PackageSpec(name="SCOTCH_jll", uuid="a8d0f55d-b80e-548d-aff6-1a04c175f0f9")),
    Dependency(PackageSpec(name="PARMETIS_jll", uuid="b247a4be-ddc1-5759-8008-7e02fe3dbdaa")),
    Dependency(PackageSpec(name="SCALAPACK32_jll", uuid="aabda75e-bfe4-5a37-92e3-ffe54af3c273")),
    Dependency(PackageSpec(name="OpenBLAS32_jll", uuid="656ef2d0-ae68-5445-9ca0-591084a874a2"))
]
append!(dependencies, platform_dependencies)

# Build the tarballs
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; augment_platform_block, julia_compat="1.6", preferred_gcc_version=v"6")
