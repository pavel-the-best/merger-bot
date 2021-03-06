FROM haskell:8.8 AS builder

WORKDIR /merger
COPY . .

RUN cabal update && cabal configure --enable-executable-stripping --enable-library-stripping && cabal install && cabal build

FROM phusion/baseimage:master

WORKDIR /merger
COPY --from=builder /merger/dist-newstyle .
ENTRYPOINT "/merger/build/x86_64-linux/ghc-8.8.4/merger-bot-0.1.0.0/x/merger-bot/build/merger-bot/merger-bot"
