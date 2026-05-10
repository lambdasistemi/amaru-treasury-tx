{- |
Module      : Amaru.Treasury.Report.Identity.Resolve
Description : Report identity resolution
License     : Apache-2.0

Compatibility module for the resolver entry points. The concrete types
live in 'Amaru.Treasury.Report.Identity'; this module names the
resolution API described by the report-render plan.
-}
module Amaru.Treasury.Report.Identity.Resolve
    ( buildAddressBook
    , buildIdentityMap
    , buildReferenceInputMap
    , resolveAddress
    , resolveReferenceInput
    , resolveSigner
    ) where

import Amaru.Treasury.Report.Identity
    ( buildAddressBook
    , buildIdentityMap
    , buildReferenceInputMap
    , resolveAddress
    , resolveReferenceInput
    , resolveSigner
    )
