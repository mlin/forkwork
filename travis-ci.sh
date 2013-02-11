# OPAM version to install
export OPAM_VERSION=0.9.1
# OPAM packages needed to build tests
export OPAM_PACKAGES='ocamlfind kaputt'

# install ocaml from apt
sudo apt-get update -qq
sudo apt-get install -qq ocaml

# install opam
curl -L https://github.com/OCamlPro/opam/archive/${OPAM_VERSION}.tar.gz | tar xz
pushd opam-${OPAM_VERSION}
./configure
make
sudo make install
popd
opam init
eval `opam config -env`

# install packages from opam
opam install -q -y ${OPAM_PACKAGES}

# compile & run tests (an OASIS DevFiles project might use ./configure --enable-tests && make test)
./configure --enable-tests
make test
