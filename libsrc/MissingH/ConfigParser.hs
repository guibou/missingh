{- arch-tag: ConfigParser main file
Copyright (C) 2004 John Goerzen <jgoerzen@complete.org>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module     : MissingH.ConfigParser
   Copyright  : Copyright (C) 2004 John Goerzen
   License    : GNU GPL, version 2 or above

   Maintainer : John Goerzen, 
   Maintainer : jgoerzen@complete.org
   Stability  : provisional
   Portability: portable

Configuration file parsing, generation, and manipulation

Copyright (c) 2004 John Goerzen, jgoerzen\@complete.org
-}
module MissingH.ConfigParser
    (
     -- * Types
     SectionSpec, OptionSpec, ConfigParser(..),
     -- * Initialization
     -- $initialization
     empty,

     -- * Reading
     -- $reading
     readfile, readhandle, readstring,

     -- * Accessing Data
     get, getbool, getnum,

     -- * Setting Data
     set, setshow,

     -- * Meta-queries
     sections, has_section,
     options, has_option,
     items,

     -- * Miscellaneous Manipulation
     add_section, merge
) where
import MissingH.ConfigParser.Types
import MissingH.ConfigParser.Parser
import MissingH.FiniteMap
import MissingH.Str
import Data.FiniteMap
import Data.List
import System.IO(Handle)
import Data.Char

{- | Combines two 'ConfigParser's into one.

Any duplicate options are resolved to contain the value specified in
the second parser.

The 'ConfigParser' options in the resulting object will be set as they
are in the second one passed to this function. -}
merge :: ConfigParser -> ConfigParser -> ConfigParser
merge src dest = 
    let conv :: String -> String
        conv = optionxform dest
        convFM :: String -> CPOptions -> CPOptions
        convFM _ = listToFM . map (\x -> (conv (fst x), snd x)) . fmToList
        in
        ConfigParser { content = plusFM (mapFM convFM (content src)) 
                                 (content dest),
                       optionxform = optionxform dest,
                       usedefault = usedefault dest,
                       defaulthandler = defaulthandler dest,
                       accessfunc = accessfunc dest}

{- | Utility to do a special case merge. -}
readutil :: ConfigParser -> ParseOutput -> ConfigParser
readutil old new = 
    let mergedest = ConfigParser {content = fromAL new,
                                  optionxform = optionxform old,
                                  usedefault = usedefault old,
                                  defaulthandler = defaulthandler old,
                                  accessfunc = accessfunc old}
        in
        merge old mergedest

{- | Loads data from the specified file.  It is then combined with the
given 'ConfigParser' using the semantics documented under 'merge' with the
new data taking precedence over the old.  However, unlike
'merge', all the options
as set in the old object are preserved since the on-disk representation
does not convey those options.

May raise an exception on a syntax error or if the file could not be
accessed.
-}
readfile :: ConfigParser -> FilePath -> IO ConfigParser
readfile cp fp = do n <- parse_file fp
                    return $ readutil cp n

{- | Like 'readfile', but uses an already-open handle.  You should
use 'readfile' instead of this if possible, since it will be able to
generate better error messages.

May raise an exception on a syntax error.
-}
readhandle :: ConfigParser -> Handle -> IO ConfigParser
readhandle cp h = do n <- parse_handle h
                     return $ readutil cp n

{- | Like 'readfile', but uses a string.  You should use 'readfile'
instead of this if you are processing a file, since it can generate
better error messages.

May raise an exception on a syntax error.
-}
readstring :: ConfigParser -> String -> ConfigParser
readstring cp s = readutil cp $ parse_string s

{- | Returns a list of sections in your configuration file.  Never includes
the always-present section @DEFAULT@. -}
sections :: ConfigParser -> [SectionSpec]
sections = filter (/= "DEFAULT") . keysFM . content

{- | Indicates whether the given section exists.

No special @DEFAULT@ processing is done. -}
has_section :: ConfigParser -> SectionSpec -> Bool
has_section cp x = elemFM x (content cp)

{- | Adds the specified section name.  Raises an exception if the
section was already present.  Otherwise, returns the new 
'ConfigParser' object.-}
add_section :: ConfigParser -> SectionSpec -> ConfigParser
add_section cp s =
    if has_section cp s
       then error ("add_section: section " ++ s ++ " already exists")
       else cp {content = addToFM (content cp) s emptyFM}

{- | Returns a list of the names of all the options present in the
given section.

Could raise an exception if the given section does not exist. -}
options :: ConfigParser -> SectionSpec -> [OptionSpec]
options cp x = keysFM (forceLookupFM "ConfigParser.options" (content cp) x)

{- | Indicates whether the given option is present.  Returns True
only if the given section is present AND the given option is present
in that section.  No special @DEFAULT@ processing is done.  No
exception could be raised.
-}
has_option :: ConfigParser -> SectionSpec -> OptionSpec -> Bool
has_option cp s o = 
    let c = content cp in
    has_section cp s &&
                elemFM (optionxform cp $ o)
                       (forceLookupFM "ConfigParser.has_option" c s) 
                           
{- | Retrieves a string from the configuration file.  Raises an exception if
no such option could be found. -}
get :: ConfigParser -> SectionSpec -> OptionSpec -> String
get cp s o = 
    case (accessfunc cp) cp s o of
         Nothing -> error $ "get: no option " ++ s ++ "/" ++ o
         Just x -> x

{- | Retrieves a string from the configuration file and attempts to parse it
as a number.  Raises an exception if no such option could be found or if it
could not be parsed as the destination number. -}
getnum :: (Read a, Num a) => ConfigParser -> SectionSpec -> OptionSpec -> a
getnum cp s o = read $ get cp s o

{- | Retrieves a string from the configuration file and attempts to parse
it as a boolean.  Raises an exception if no such option could be found or
if it could not be parsed as a boolean. -}
getbool :: ConfigParser -> SectionSpec -> OptionSpec -> Bool
getbool cp s o = 
    case map toLower . strip . get cp s $ o of
         "1" -> True
         "yes" -> True
         "on" -> True
         "enabled" -> True
         "0" -> False
         "no" -> False
         "off" -> False
         "disabled" -> False
         _ -> error ("getbool: couldn't parse " ++ get cp s o ++ " from " ++
                     s ++ "/" ++ o)

{- | Returns a list of @(optionname, value)@ pairs representing the content
of the given section.  Raises an error if the section is invalid. -}
items :: ConfigParser -> SectionSpec -> [(OptionSpec, String)]
items cp s = fmToList (forceLookupFM "ConfigParser.items" (content cp) s)

{- | Sets the option to a new value, replacing an existing one if it exists.
Raises an error if the section does not exist. -}
set :: ConfigParser -> SectionSpec -> OptionSpec -> String -> ConfigParser
set cp s passedo val = 
    cp { content = newmap}
    where newmap = addToFM (content cp) s newsect
          newsect = addToFM sectmap o val
          sectmap = forceLookupFM "ConfigParser.set" (content cp) s
          o = (optionxform cp) passedo

{- | Sets the option to a new value, replacing an existing one if it exists.
It requires only a showable value as its parameter.
This can be used with bool values, as well as numeric ones.  Raises
an error if the section does not exist. -}
setshow :: Show a => ConfigParser -> SectionSpec -> OptionSpec -> a -> ConfigParser
setshow cp s o val = set cp s o (show val)

{- | Converts the 'ConfigParser' to a string representation that could be
later re-parsed by this module. -}
to_string :: ConfigParser -> String
to_string cp = 
    let gen_option (key, value) = 
            key ++ ": " ++ (replace "\n" "\n " value) ++ "\n"
        gen_section (sect, valfm) = 
            "[" ++ sect ++ "]\n" ++
                (concat $ map gen_option (fmToList valfm)) ++ "\n"
        in
        concat $ map gen_section (fmToList (content cp))

----------------------------------------------------------------------
-- Docs
----------------------------------------------------------------------

{- $initialization

The variable 'empty' is exported, and contains a default empty
'ConfigParser'.
-}

{- $reading

You can use these functions to read data from a file.

A common idiom for loading a new object from stratch is:

@cp <- 'readfile' 'empty' \"\/etc\/foo.cfg\"@

Note the use of 'empty'; this will essentially cause the file's data
to be merged with the empty 'ConfigParser'.
-}