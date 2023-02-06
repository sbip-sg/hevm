# README HEVM 0.48.1

To build HEVM by cabal, check out the README file at `hevm/src/hevm/README.md`.
You may also need to install `libff` or build it manually.

Below are the detailed steps:

1. Build `libff` manually from source code:

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

2. Build HEVM using :

   ```sh
   cd src/hevm
   cabal v2-update
   cabal v2-configure
   cabal build --enable-executable-static \
       --extra-lib-dirs=/usr/local/lib \
       --extra-include-dirs=/usr/local/include/libff/
   ```

   After that, the binary file `hevm` will be compiled to the path like:
   `src/hevm/dist-newstyle/build/x86_64-linux/ghc-8.8.4/hevm-0.50.0/x/hevm/build/hevm/hevm`
