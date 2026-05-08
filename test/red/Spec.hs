{-# OPTIONS_GHC -F -pgmF hspec-discover #-}

{- |
Module      : Spec
Description : Hspec entry point for the red-tests TDD bucket
License     : Apache-2.0

Hosts assertions that capture intended post-fix behavior **before**
the implementation lands. Tests in this suite are expected to fail
on the current builder and pass once the corresponding green-step
task ships. Not part of the default gate; run with @just red@ or
@cabal test red-tests@ to see the executable red proof.
-}
