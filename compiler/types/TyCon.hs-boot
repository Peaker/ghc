module TyCon where

import Name (Name)
import Unique (Unique)

data TyCon

tyConName           :: TyCon -> Name
tyConUnique         :: TyCon -> Unique
isTupleTyCon        :: TyCon -> Bool
isUnboxedTupleTyCon :: TyCon -> Bool
isFunTyCon          :: TyCon -> Bool
