HEVM -- SBIP
=======================

# Installation
## Build native hevm:

1. Build https://github.com/scipr-lab/libff v0.2.1 manually and install it
   locally (by default, it will be installed to `/usr/local/`):

   ```sh
   git clone https://github.com/scipr-lab/libff
   cd libff
   git submodule init && git submodule update
   git fetch --all --tags
   git checkout tags/v0.2.1
   mkdir build & cd build;
   cmake .. -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DWITH_PROCPS=OFF
   make
   sudo make install
   ```

2. After that run `cabal` to build HEVM with `--extra-lib-dirs` and
        `--extra-include-dirs`:

   ```sh
   cabal build --enable-executable-static \
         --extra-lib-dirs=/usr/local/lib \
         --extra-include-dirs=/usr/local/include/libff/

   cabal build exe:hevm --enable-executable-static \
         --extra-lib-dirs=/usr/local/lib \
         --extra-include-dirs=/usr/local/include/libff/
   ```

The output file `hevm` will be built to the path like:
`hevm/src/hevm/dist-newstyle/build/x86_64-linux/ghc-8.8.4/hevm-0.50.0/x/hevm/build/hevm/hevm`
(specific version of GHC and HEVM may be different).
