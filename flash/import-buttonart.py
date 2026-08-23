# Adds the two tags the menu needs that FFDec's -replace cannot add itself.
#
#   ImportAssets2  "ButtonArt"      -- SkyUI's key/button glyph strip
#   ExportAssets   "CalendarPanel"  -- the base movie's own panel art
#
# Both are spliced at the XML level: swf2xml -> here -> xml2swf.

import io,sys
src,dst = sys.argv[1],sys.argv[2]
s = io.open(src,encoding="utf-8").read()

# --- ImportAssets2: ButtonArt from SkyUI -------------------------------
#
# The url needs a DOUBLED backslash. That is FFDec's own escaping on export;
# a single one is folded into a 0x08 backspace, silently corrupting the path
# so the import resolves to nothing and every icon renders blank.
if "ButtonArt" not in s:
    BS2 = chr(92)*2
    tag = ('<item type="ImportAssets2Tag" downloadNow="1" forceWriteAsLong="true" '
           'hasDigest="0" url="skyui' + BS2 + 'buttonart.swf">' + chr(10) +
           "<tags>" + chr(10) + "<item>200</item>" + chr(10) + "</tags>" + chr(10) +
           "<names>" + chr(10) + "<item>ButtonArt</item>" + chr(10) + "</names>" + chr(10) +
           "</item>" + chr(10))
    for anchor in ('<item type="DefineBitsLossless2Tag"', '<item type="DefineShape'):
        i = s.find(anchor)
        if i > 0: break
    else:
        raise SystemExit("no anchor found for the ButtonArt import")
    s = s[:i] + tag + s[i:]
    print("injected ButtonArt at", i)

# --- ExportAssets: the panel art as "CalendarPanel" --------------------
#
# Sprite 11 is Background_mc -- the vanilla panel, carrying its own
# DefineScalingGrid so it 9-slices correctly at any size. The base movie does
# not export it, so attachMovie cannot reach it; this adds the tag.
#
# Deliberately NOT reusing the "MessageBox" symbol (chid 15), which is
# exported and holds the same art: registerClass binds that symbol to our own
# menu class, so attaching it would construct a second entire calendar rather
# than a blank panel.
#
# The export must come AFTER the sprite it names, or the id resolves to
# nothing -- anchoring on the existing MessageBoxButton export guarantees it.
if "CalendarPanel" not in s:
    export = ('<item type="ExportAssetsTag" forceWriteAsLong="true">' + chr(10) +
              "<tags>" + chr(10) + "<item>11</item>" + chr(10) + "</tags>" + chr(10) +
              "<names>" + chr(10) + "<item>CalendarPanel</item>" + chr(10) +
              "</names>" + chr(10) + "</item>" + chr(10))
    j = s.find('<item type="ExportAssetsTag"', s.find("MessageBoxButton"))
    if j < 0:
        raise SystemExit("no anchor found for the CalendarPanel export")
    s = s[:j] + export + s[j:]
    print("exported CalendarPanel (sprite 11) at", j)

io.open(dst,"w",encoding="utf-8",newline=chr(10)).write(s)
