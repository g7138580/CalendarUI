// CalendarUI -- the calendar as a real Skyrim menu.
//
// NOTE THE CLASS NAME. This must stay `MessageBox`, even though nothing here
// is a message box, because the base movie ends with:
//
//     Object.registerClass("MessageBox", MessageBox);
//
// That shim binds the *symbol* "MessageBox" -- the sprite the stage places as
// `MessageMenu` -- to whatever `_global.MessageBox` holds. FFDec replaces the
// body of `__Packages/MessageBox`, but the class statement inside it is what
// decides which global gets defined. Naming the class `CalendarMenu` defined
// `_global.CalendarMenu` and left `_global.MessageBox` undefined, so
// registerClass bound nothing: the sprite fell back to a plain MovieClip, the
// constructor never ran, `addCallBack("setCalendarData")` was never
// registered, and the movie sat there showing the authored placeholder text
// while the plugin's FxDelegate::Invoke had no receiver.
//
// The symptom of getting this wrong is a vanilla-looking message box reading
// "<message text>" and nothing else.
//
// This class replaces MessageBox inside a copy of the game's own
// messagebox.swf. That is deliberate, and it is the whole point of this
// approach: by starting from a vanilla menu we inherit, unmodified,
//
//   * Background_mc     the real border and panel art, at the right weight
//   * MessageBoxButton  a focusable button with a selection indicator
//   * DiamondMarker     the vanilla divider ornament
//   * the game's fonts, referenced by name rather than loaded
//   * handleInput       keyboard AND gamepad navigation
//   * GameDelegate      the call/callback bridge to the SKSE plugin
//
// None of that has to be imitated; it is the game's own art and code.
//
// The C++ side sends a month with CalendarUI::PushMonth and this lays it out;
// it computes no dates itself. Skyrim derives the weekday from GameDaysPassed
// rather than from the date, so it cannot be recomputed here -- see
// GameDate::WeekdayOf.

class MessageBox extends MovieClip
{
   // On the stage, inherited from messagebox.swf. These are the ONLY named
   // instances it defines -- confirmed from the SWF's PlaceObject tags -- so
   // every other text field this menu needs is created at runtime below.
   var Background_mc;
   var Divider;
   var MessageText;

   // Created in BuildText(). Referencing stage names that do not exist is
   // what left the vanilla "<message text>" placeholder on screen: the class
   // bound fine, but every assignment went to undefined.
   var HeadingText;
   var TodayText;
   var DetailText;
   var PromptBar;     // the prompt row, under the sub-line
   var Prompts;       // the individual icon+caption clips
   var bGamepad;
   var PendingKeys;

   // The day-detail popup. Non-null only while it is open, which is also the
   // flag handleInput uses to decide who owns the keyboard.
   var Popup;


   // The bound keys, as VK codes -- converted once in SetKeys, the way
   // CharacterSheet.SetGamepad does it, so handleInput compares directly.
   // Keyboard and gamepad are held separately and both are tested on every
   // branch, so no platform flag can put them out of step.
   var KeyPrev;
   var KeyNext;
   var KeyToday;
   var KeyClose;
   var KeyPrevPad;
   var KeyNextPad;
   var KeyTodayPad;
   var KeyClosePad;

   // Built at runtime.
   var Cells;            // the 42 day buttons
   var CellContainer;
   var HeaderContainer;
   var FrameContainer;

   // The note editor. Editing is the flag handleInput checks FIRST -- while it
   // is true the keyboard belongs to Flash, not to the game or this menu.
   var Editing;
   var EditLayer;
   var EditName;
   var EditDesc;
   var EditNameLabel;
   var EditDescLabel;
   var EditField;        // 0 = name, 1 = description
   var EditDay;

   // What held focus before the editor opened, restored on close.
   var PreviousFocus;

   // The note editor's keys, as DX scan codes from the INI. Defaults match
   // Settings.h so the editor still works if setNoteKeys never arrives.
   var NoteKeyScan = 49;        // N
   var NoteSaveScan = 28;       // Enter
   var NoteCancelScan = 1;      // Escape
   var NoteSwitchScan = 15;     // Tab
   var NoteDeleteScan = 62;     // F4
   var NoteDeleteCtrl = false;

   // The delete confirmation. Confirming gates handleInput the way Editing
   // does, so the question is genuinely modal.
   var Confirming;
   var ConfirmLayer;
   var ConfirmPromptBar;
   var ConfirmPrompts;

   // The editor's own prompt bar.
   var EditPromptBar;
   var EditPrompts;

   // The day popup's own one-prompt bar ("Add note" / "Edit note").
   var PopupPromptBar;
   var PopupPrompts;

   // The icons drawn beside No and Yes, as ButtonArt frame numbers. Escape and
   // Enter on a keyboard; SetKeys swaps in the gamepad pair when one is in use,
   // exactly as the prompt bar does.

   // The day the popup is showing, so the note key knows what it is editing.
   var PopupDay;

   var Data;             // the month object from C++
   var SelectedIndex;
   var iPlatform;

   // Measured from the base SWF rather than guessed. MessageBoxButton
   // (sprite 9) carries a ButtonText field with bounds 100x55px placed at
   // x=-48, so a cell's natural width is ~100. Laying cells out closer than
   // that without resizing them overlaps the vanilla art; CELL_W is therefore
   // the size we pass to setSize(), not just a stride.
   static var COLS = 7;
   static var ROWS = 6;
   static var CELL_W = 100;
   static var CELL_GAP = 6;

   // --- vertical fit -----------------------------------------------------
   //
   // The stage is 1280x720 and MessageMenu is placed at its centre, so the
   // whole panel has 720 units of height to live in NO MATTER the player's
   // resolution -- Skyrim scales the movie to the screen, it does not give
   // the movie more room on a bigger monitor. A panel taller than this is
   // clipped equally top and bottom.
   //
   // CELL_H is therefore NOT a constant. It is the preferred height, clamped
   // at runtime by FitCellHeight() to whatever actually fits once the header,
   // footer and margins have taken their share. Hardcoding it is what put the
   // menu off-screen: 6 rows at 80 plus the fixed furniture came to 812.
   static var STAGE_H = 720;
   static var STAGE_W = 1280;

   // Kept off the very edge of the screen, and away from Skyrim's own
   // letterboxing on unusual aspect ratios.
   static var SCREEN_PAD = 20;

   static var CELL_H_PREFERRED = 80;
   static var CELL_H_MIN = 44;

   // Set by FitCellHeight before any layout runs. Every consumer reads this,
   // never CELL_H_PREFERRED.
   static var CELL_H = 80;

   // --- cell frames ------------------------------------------------------
   //
   // The vanilla MessageBoxButton is a wide, borderless plate: seven of them
   // in a row read as a row of buttons, not a calendar. So each cell gets a
   // drawn box BEHIND the button -- border plus fill -- while the button
   // itself stays for focus, selection and gamepad navigation.
   //
   // Drawn rather than art from the base SWF because messagebox.swf has no
   // square frame symbol to attach, and drawing needs no new tag in the SWF.
   static var FRAME_LINE = 1;
   static var FRAME_LINE_COLOR = 0x9A8B6A;   // the UI's muted gold
   static var FRAME_LINE_ALPHA = 55;
   static var FRAME_FILL_COLOR = 0x000000;
   static var FRAME_FILL_ALPHA = 35;

   // Today's cell is called out by its frame instead of only by bold text.
   static var FRAME_TODAY_COLOR = 0xE8D9A0;
   static var FRAME_TODAY_ALPHA = 100;

   // The vanilla selection indicator is not used at all.
   //
   // It is drawn for a wide message-box button and swamps a calendar cell;
   // scaling it down to fit made it vanish instead. Since the cells already
   // have a drawn frame, selection is shown by lighting THAT up -- the same
   // treatment today's cell gets, one visual language for both.
   //
   // The vanilla art is hidden rather than left at natural size, because it
   // would otherwise sit inside the frame competing with it.
   static var SELECTION_COLOR = 0xFFFFFF;
   static var SELECTION_ALPHA = 100;
   static var SELECTION_LINE = 2;

   // Today, when it is also the selected cell. Selection wins on colour --
   // it is the thing the player is moving -- so today keeps its identity
   // through the thicker border alone.
   static var TODAY_LINE = 2;

   // --- Moon phases -------------------------------------------------------
   //
   // All eight phases, drawn in a cell's top-right corner. The values match
   // RE::Moon::Phase exactly, which is what C++ sends -- the enum runs full,
   // then wanes to new, then waxes back.
   static var MOON_FULL = 0;
   static var MOON_WANING_GIBBOUS = 1;
   static var MOON_THIRD_QUARTER = 2;
   static var MOON_WANING_CRESCENT = 3;
   static var MOON_NEW = 4;
   static var MOON_WAXING_CRESCENT = 5;
   static var MOON_FIRST_QUARTER = 6;
   static var MOON_WAXING_GIBBOUS = 7;

   // Where the terminator sits for the crescent and gibbous phases.
   //
   // The lit fraction is (1 + k) / 2, so 0.5 puts the crescents at a quarter
   // lit and the gibbous phases at three quarters -- the true quarter points
   // of the cycle, and far enough either side of the half-lit quarters to be
   // told apart at this size.
   static var MOON_LUNE_K = 0.5;

   // Radius of the disc, and its inset from the cell's top-right corner.
   //
   // Small on purpose. This is a margin note on the day, not a feature of it:
   // it has to be readable at a glance without competing with the day number
   // or the event name for attention.
   static var MOON_R = 7;
   static var MOON_INSET = 11;

   // The lit face, and the unlit body behind it.
   //
   // The dark side is DRAWN rather than left empty. A new moon has no lit part
   // at all, so with nothing behind it the cell would show a blank corner --
   // indistinguishable from a day with no phase marked. The outline is what
   // says "this is a moon, and it is dark" instead of "nothing here".
   static var MOON_LIT_COLOR = 0xE8D9A0;     // the same gold as today's frame
   static var MOON_LIT_ALPHA = 100;
   static var MOON_DARK_COLOR = 0x1A1A1A;
   static var MOON_DARK_ALPHA = 100;
   static var MOON_EDGE_COLOR = 0x9A8B6A;
   static var MOON_EDGE_ALPHA = 70;
   static var MOON_EDGE_LINE = 1;

   // Below DEPTH_CELLS so every frame sits behind every button.
   static var DEPTH_FRAMES = 99;
   static var MARGIN = 34;
   static var HEADER_H = 128;
   // The detail panel: a divider plus DETAIL_LINES lines of text.
   //
   // A literal, not an expression over the two constants below. AS2 evaluates
   // static initialisers in declaration order, so a forward reference here
   // would silently produce NaN and collapse the panel. The arithmetic is
   // 24 (divider) + 3 * 24 (lines) + 10 (padding).
   static var FOOTER_H = 106;

   // Three lines, not two: the head (date + holiday name) always takes one,
   // leaving two for the description. At 15pt across the grid width a line
   // holds roughly 95 characters, so this covers descriptions to about 190 --
   // past the longest vanilla one (107). Longer still clips, by design.
   static var DETAIL_LINES = 3;
   static var DETAIL_LINE_H = 24;

   function MessageBox()
   {
      super();
      this.Cells = new Array();
      this.SelectedIndex = -1;
      this.iPlatform = 0;

      // Explicitly false, not merely undefined: handleInput tests this on
      // every keystroke and an undefined would work by accident rather than by
      // contract.
      this.Editing = false;

      // Kept because the vanilla MessageBox constructor does it, and the class
      // is a drop-in replacement for that symbol. Nothing here defines
      // onKeyDown any more: the editor reads Key.isDown directly for the CTRL
      // state, and every key that needs acting on goes through handleInput,
      // which -- unlike a Key listener -- can actually consume the event.
      Key.addListener(this);

      // A plain MovieClip is not focusable by default, and Selection.setFocus
      // silently does nothing on one that is not. ClearSelection focuses this
      // menu when no day is selected, so it has to be able to hold focus --
      // otherwise the focus path goes empty and handleInput stops being
      // called, which kills every key while leaving the mouse working.
      this.focusEnabled = true;
      this.tabEnabled = false;

      this.BuildText();

      // BuildNav is deliberately NOT called here -- see BuildNav's comment.
      // Nothing attached with attachMovie has its frame-1 children yet at
      // constructor time.

      // What the plugin calls on us.
      gfx.io.GameDelegate.addCallBack("setCalendarData", this, "SetCalendarData");
      gfx.io.GameDelegate.addCallBack("setPlatform", this, "SetPlatform");
      gfx.io.GameDelegate.addCallBack("setKeys", this, "SetKeys");
      gfx.io.GameDelegate.addCallBack("setNoteKeys", this, "SetNoteKeys");
   }

   // The game's font, referenced the way the vanilla fields reference it.
   //
   // messagebox.swf imports its font from gfxfontlib.swf as the alias
   // "$EverywhereMediumFont" and names it *inline in the HTML* --
   //
   //     <font face="$EverywhereMediumFont" size="22" ...>
   //
   // -- rather than through a TextFormat. Fields created at runtime with
   // createTextField() therefore get no usable font: setNewTextFormat() does
   // not carry the imported-font binding across, so every glyph renders as an
   // empty box. Wrapping our own markup in the same <font> tag is what makes
   // runtime text look like the rest of the UI.
   static var FONT = "$EverywhereMediumFont";
   static var FONT_SIZE = 22;
   static var FONT_SIZE_SMALL = 18;

   // Event names sit under the day number inside a 100px cell, so they get
   // their own smaller size. See BuildGrid, where the cell's text field is
   // also switched to wordWrap so a long name wraps instead of bleeding
   // across neighbouring cells ("Harvest's End" spanning three columns).
   static var FONT_SIZE_EVENT = 12;
   static var FONT_SIZE_HINT = 15;

   // Raw key codes. NavigationCode only covers mapped navigation (arrows,
   // pageUp/Down, the face buttons); plain letters are not in it, so these
   // are matched against details.code instead.
   // Prompt bar metrics.
   static var ScanTable;

   // Scan code -> printable name, for the editor's hint line. Built lazily by
   // ScanName.
   static var ScanNames;

   // Gap between a prompt's icon and its caption. The icon's own width is
   // measured at build time, so this is only the space after it.
   static var PROMPT_ICON_GAP = 8;
   static var PROMPT_GAP = 26;
   static var PROMPT_HIT_H = 26;


   // Depths for the two containers BuildGrid recreates each month. Well above
   // anything the constructor allocates via getNextHighestDepth().
   static var DEPTH_HEADERS = 100;
   static var DEPTH_CELLS = 101;
   static var DEPTH_PROMPTS = 102;

   // Above everything else in the menu.
   static var DEPTH_POPUP = 200;

   // Popup metrics. The width is fixed; the height is MEASURED from the
   // wrapped text, so a long description extends the panel rather than being
   // clipped -- which is the whole point of showing it in a popup.
   // Matches the clamp in Notes.cpp. A longer string would be truncated on the
   // C++ side, so the field refuses it rather than showing text that will not
   // survive the save.
   static var NOTE_MAX_CHARS = 1024;

   // VIRTUAL key codes, matching what SetKeys already converts its bindings to
   // -- details.code carries VK values here, not DirectInput scan codes.
   //
   // Tested alongside navEquivalent rather than instead of it: navEquivalent
   // covers Enter and Escape once the game has mapped them, but an input field
   // with focus can change what gets mapped, and Tab has no navEquivalent at
   // all. Checking both is what makes the editor's keys reliable.
   static var KEY_TAB = 9;
   static var KEY_ENTER = 13;
   static var KEY_ESCAPE = 27;

   // DirectInput SCAN codes, for skse.GetLastKeycode() -- the editor matches
   // on these because the VK values above are what the binding layer rewrites
   // keys INTO, and are therefore useless for telling real keys apart.
   static var SCAN_ESCAPE = 1;
   static var SCAN_TAB = 15;
   static var SCAN_ENTER = 28;
   static var SCAN_UNKNOWN = -1;


   static var POPUP_W = 520;
   static var POPUP_PAD = 30;
   static var POPUP_MIN_H = 110;

   // The delete confirmation window. Smaller than the day popup: it holds one
   // question and two options, and a panel sized for prose would dwarf them.
   static var CONFIRM_W = 400;
   static var CONFIRM_H = 130;
   static var CONFIRM_GAP = 48;

   // The note editor's window. Wider than the confirmation because it holds
   // two text fields and a hint line; the height covers the fields' existing
   // layout, which runs from the heading at -100 to the hint at +76.
   static var EDIT_W = 520;
   static var EDIT_H = 232;

   // Tighter than the main bar's PROMPT_GAP: four prompts have to fit inside
   // EDIT_W, where the menu's own bar has the whole panel width.
   static var EDIT_PROMPT_GAP = 18;

   // Room the day popup leaves for its note prompt, below the body text.
   static var POPUP_PROMPT_H = 34;


   // Wraps already-marked-up runs in one centred paragraph.
   //
   // Separate <p> blocks each carry their own margins; a <br/> inside a single
   // paragraph gives a plain line break instead. Everything written to a text
   // field goes through a Markup* function so the build can verify the font
   // tag is present -- hand-rolling the <p> here would defeat that check.
   function MarkupBlock(asInner)
   {
      return "<p align='center'>" + asInner + "</p>";
   }

   // Two lines in ONE centred paragraph.
   //
   // Separate <p> blocks each carry their own margins, which overflowed the
   // fixed-height detail field and hid the second line completely. A <br/>
   // inside a single paragraph gives a plain line break instead.
   function Markup2(asTop, aiTopSize, asBottom, aiBottomSize)
   {
      var inner = this.Markup(asTop, aiTopSize, false);
      if(asBottom.length > 0)
      {
         inner = inner + "<br/>" + this.Markup(asBottom, aiBottomSize, false);
      }
      return "<p align='center'>" + inner + "</p>";
   }

   // Wraps markup in the vanilla font tag. Everything this menu writes to a
   // text field goes through here.
   function Markup(asText, aiSize, abCenter)
   {
      var size = aiSize == undefined ? MessageBox.FONT_SIZE : aiSize;
      var open = "<font face='" + MessageBox.FONT + "' size='" + size
               + "' color='#ffffff' letterSpacing='0.800000' kerning='0'>";
      var body = open + asText + "</font>";
      return abCenter ? "<p align='center'>" + body + "</p>" : body;
   }

   // Creates the three text fields the calendar needs. MessageText is the
   // only one the stage provides, and it is reused as the heading so its
   // vanilla text format (the game's font, already applied) carries over.
   function BuildText()
   {
      // Reused so the vanilla text format (the game's font, already applied)
      // carries over. The stage field is multiline with wordWrap on and is
      // 348x119px -- autoSize on top of that fights the explicit _width set
      // in ResetDimensions, so the heading is sized by hand instead.
      this.HeadingText = this.MessageText;
      this.HeadingText.autoSize = "none";
      this.HeadingText.multiline = false;
      this.HeadingText.wordWrap = false;
      this.HeadingText.selectable = false;
      this.HeadingText.html = true;
      this.HeadingText.noTranslate = true;

      var fmt = this.MessageText.getTextFormat();

      this.createTextField("TodayField", this.getNextHighestDepth(), 0, 0, 400, 24);
      this.TodayText = this["TodayField"];
      this.TodayText.selectable = false;
      this.TodayText.html = true;
      this.TodayText.noTranslate = true;
      this.TodayText.setNewTextFormat(fmt);

      this.createTextField("DetailField", this.getNextHighestDepth(), 0, 0, 400, 60);
      this.DetailText = this["DetailField"];
      this.DetailText.selectable = false;
      this.DetailText.html = true;
      this.DetailText.multiline = true;
      this.DetailText.wordWrap = true;
      this.DetailText.noTranslate = true;
      this.DetailText.setNewTextFormat(fmt);
   }

   // DX scan code -> Windows virtual-key code.
   //
   // This is Character Menu SE's DxScanToWindows table, verbatim -- all 114
   // entries, extracted from charactersheet.swf rather than retyped. Two
   // details in it were things I had guessed wrong:
   //
   //   * unknown codes return 0, NOT the input unchanged
   //   * gamepad codes are NOT passed through -- they are mapped like any
   //     other (A 276 -> 13, B 277 -> 9, LB 274 -> 100, RB 275 -> 103)
   //
   // A lookup object rather than a switch: AS2 compiles switch to strict
   // equality and these values arrive from C++ as Numbers, so integer cases
   // never match.
   static function ScanToVK(aiScan)
   {
      if(MessageBox.ScanTable == undefined)
      {
         MessageBox.ScanTable = new Object();
         MessageBox.ScanTable[1] = 27;
         MessageBox.ScanTable[2] = 49;
         MessageBox.ScanTable[3] = 50;
         MessageBox.ScanTable[4] = 51;
         MessageBox.ScanTable[5] = 52;
         MessageBox.ScanTable[6] = 53;
         MessageBox.ScanTable[7] = 54;
         MessageBox.ScanTable[8] = 55;
         MessageBox.ScanTable[9] = 56;
         MessageBox.ScanTable[10] = 57;
         MessageBox.ScanTable[11] = 48;
         MessageBox.ScanTable[12] = 189;
         MessageBox.ScanTable[13] = 187;
         MessageBox.ScanTable[14] = 8;
         MessageBox.ScanTable[15] = 9;
         MessageBox.ScanTable[16] = 81;
         MessageBox.ScanTable[17] = 38;
         MessageBox.ScanTable[18] = 69;
         MessageBox.ScanTable[19] = 82;
         MessageBox.ScanTable[20] = 84;
         MessageBox.ScanTable[21] = 89;
         MessageBox.ScanTable[22] = 85;
         MessageBox.ScanTable[23] = 73;
         MessageBox.ScanTable[24] = 79;
         MessageBox.ScanTable[25] = 80;
         MessageBox.ScanTable[26] = 219;
         MessageBox.ScanTable[27] = 221;
         MessageBox.ScanTable[28] = 13;
         MessageBox.ScanTable[29] = 17;
         MessageBox.ScanTable[30] = 37;
         MessageBox.ScanTable[31] = 40;
         MessageBox.ScanTable[32] = 39;
         MessageBox.ScanTable[33] = 70;
         MessageBox.ScanTable[34] = 71;
         MessageBox.ScanTable[35] = 72;
         MessageBox.ScanTable[36] = 74;
         MessageBox.ScanTable[37] = 75;
         MessageBox.ScanTable[38] = 76;
         MessageBox.ScanTable[39] = 186;
         MessageBox.ScanTable[40] = 222;
         MessageBox.ScanTable[41] = 192;
         MessageBox.ScanTable[42] = 160;
         MessageBox.ScanTable[43] = 220;
         MessageBox.ScanTable[44] = 90;
         MessageBox.ScanTable[45] = 88;
         MessageBox.ScanTable[46] = 67;
         MessageBox.ScanTable[47] = 86;
         MessageBox.ScanTable[48] = 66;
         MessageBox.ScanTable[49] = 78;
         MessageBox.ScanTable[50] = 77;
         MessageBox.ScanTable[51] = 188;
         MessageBox.ScanTable[52] = 190;
         MessageBox.ScanTable[53] = 191;
         MessageBox.ScanTable[54] = 161;
         MessageBox.ScanTable[55] = 106;
         MessageBox.ScanTable[56] = 164;
         MessageBox.ScanTable[57] = 32;
         MessageBox.ScanTable[58] = 20;
         MessageBox.ScanTable[59] = 112;
         MessageBox.ScanTable[60] = 113;
         MessageBox.ScanTable[61] = 114;
         MessageBox.ScanTable[62] = 115;
         MessageBox.ScanTable[63] = 116;
         MessageBox.ScanTable[64] = 117;
         MessageBox.ScanTable[65] = 118;
         MessageBox.ScanTable[66] = 119;
         MessageBox.ScanTable[67] = 120;
         MessageBox.ScanTable[68] = 121;
         MessageBox.ScanTable[87] = 122;
         MessageBox.ScanTable[88] = 123;
         MessageBox.ScanTable[71] = 103;
         MessageBox.ScanTable[72] = 104;
         MessageBox.ScanTable[73] = 105;
         MessageBox.ScanTable[74] = 109;
         MessageBox.ScanTable[75] = 100;
         MessageBox.ScanTable[76] = 101;
         MessageBox.ScanTable[77] = 102;
         MessageBox.ScanTable[78] = 107;
         MessageBox.ScanTable[79] = 97;
         MessageBox.ScanTable[80] = 98;
         MessageBox.ScanTable[81] = 99;
         MessageBox.ScanTable[82] = 96;
         MessageBox.ScanTable[83] = 110;
         MessageBox.ScanTable[156] = 13;
         MessageBox.ScanTable[69] = 144;
         MessageBox.ScanTable[70] = 145;
         MessageBox.ScanTable[157] = 163;
         MessageBox.ScanTable[181] = 111;
         MessageBox.ScanTable[183] = 44;
         MessageBox.ScanTable[184] = 165;
         MessageBox.ScanTable[197] = 19;
         MessageBox.ScanTable[199] = 36;
         MessageBox.ScanTable[200] = 38;
         MessageBox.ScanTable[201] = 33;
         MessageBox.ScanTable[203] = 37;
         MessageBox.ScanTable[205] = 39;
         MessageBox.ScanTable[207] = 35;
         MessageBox.ScanTable[208] = 40;
         MessageBox.ScanTable[209] = 34;
         MessageBox.ScanTable[210] = 45;
         MessageBox.ScanTable[211] = 46;
         MessageBox.ScanTable[256] = 1;
         MessageBox.ScanTable[257] = 2;
         MessageBox.ScanTable[258] = 4;
         MessageBox.ScanTable[276] = 13;
         MessageBox.ScanTable[277] = 9;
         MessageBox.ScanTable[278] = 98;
         MessageBox.ScanTable[279] = 99;
         MessageBox.ScanTable[280] = 101;
         MessageBox.ScanTable[281] = 104;
         MessageBox.ScanTable[274] = 100;
         MessageBox.ScanTable[275] = 103;
         MessageBox.ScanTable[272] = 102;
         MessageBox.ScanTable[273] = 105;
      }
      return MessageBox.ScanTable[aiScan] || 0;
   }

   // ---- input ---------------------------------------------------------
   //
   // Gamepad support is not extra work here: navEquivalent already maps the
   // d-pad and face buttons alongside the keyboard, because this is the same
   // handler every vanilla menu uses.
   function handleInput(details, pathToFocus)
   {
      var handled = false;

      // THE EDITOR OWNS THE KEYBOARD. Checked before everything else,
      // including the popup branch below.
      //
      // Only three keys act: Tab moves between the fields, Enter saves, Escape
      // cancels. EVERY other key is passed down pathToFocus so the focused
      // input field receives it as a character -- and then true is returned
      // regardless, so nothing reaches the grid, the month keys, or the game.
      //
      // Escape is handled HERE rather than falling through to the close
      // branch: without this, cancelling an edit would close the whole menu
      // and (worse) skip EndEdit, leaving AllowTextInput on.
      // WHILE EDITING, THIS MENU'S JOB IS TO GET OUT OF THE WAY.
      //
      // Typed characters never travel through handleInput. Scaleform routes
      // them straight to whatever Selection.setFocus points at -- but only if
      // the menu does NOT claim the event: FocusHandler.handleInput continues
      // past the menu only when the menu returns something other than true.
      //
      // So returning true here (to "block" keys) is exactly what stops the
      // field ever receiving a character. It looks identical to the game
      // eating the keys, and it is the reason the box appeared frozen.
      //
      // Nor may pathToFocus be delegated down: a bare TextField has no
      // handleInput, so getPathToFocus does not include it, and delegating
      // just calls this menu again.
      //
      // Esc / Enter / Tab come from onKeyDown instead, off the real scan code.
      // Only the gamepad is handled here, because it produces no scan code.
      // Modelled on skyui.components.SearchWidget.handleInput, which is the
      // working reference for a Scaleform text field in Skyrim.
      //
      // Two things there matter and both were wrong here before:
      //
      //   * Enter / Tab / Escape are matched on navEquivalent, and end the
      //     edit. They are NOT returned true for -- SearchWidget falls through
      //     to the delegation below even for these.
      //
      //   * The event is then delegated with pathToFocus.shift(), and only its
      //     answer decides the return value. Returning true unconditionally
      //     (to "block" keys) is what stops characters reaching the field.
      // The delete confirmation owns the keyboard while it is open.
      //
      // Checked before the editor branch and returns true for EVERYTHING, so
      // no keystroke reaches the text fields behind it -- a modal question
      // that let you keep typing into the box underneath would be a lie.
      // Modelled on the vanilla MessageBox, which is the game's own Yes/No
      // dialog and what the wait menu's confirmation is built from:
      //
      //   * ESCAPE, GAMEPAD_B and TAB all cancel. Tab included -- vanilla
      //     treats it as a cancel, not as a field switch, and matching that is
      //     the whole point of this window feeling native.
      //   * Everything else is delegated to the focused button, which is a
      //     real gfx.controls.Button and handles its own arrows and Enter.
      // Enter answers Yes, Tab answers No -- the vanilla wait menu's own
      // scheme, where each answer has its own key and there is nothing to
      // select. Escape and Gamepad-B also cancel, as they do everywhere.
      //
      // Every key is swallowed regardless, so nothing behind this window can
      // act while it is up.
      if(this.Confirming)
      {
         if(Shared.GlobalFunc.IsKeyPressed(details))
         {
            if(details.navEquivalent == gfx.ui.NavigationCode.ENTER
               || details.navEquivalent == gfx.ui.NavigationCode.GAMEPAD_A)
            {
               this.OnConfirmYes();
            }
            else if(details.navEquivalent == gfx.ui.NavigationCode.TAB
                    || details.code == 9
                    || details.navEquivalent == gfx.ui.NavigationCode.ESCAPE
                    || details.navEquivalent == gfx.ui.NavigationCode.GAMEPAD_B)
            {
               this.OnConfirmNo();
            }
         }

         return true;
      }

      if(this.Editing)
      {
         if(Shared.GlobalFunc.IsKeyPressed(details))
         {
            // The delete combination, handled HERE rather than in onKeyDown.
            //
            // onKeyDown is only a listener -- it can see the key but cannot
            // stop it, so the "d" of Ctrl+D was still typed into the field.
            // Returning true from handleInput is what actually swallows it.
            //
            // The scan code comes from skse.GetLastKeycode because inside a
            // focused field details.code is the binding, not the key; the CTRL
            // state comes from Key.isDown, which details does not carry.
            var delScan = MessageBox.SCAN_UNKNOWN;
            if(skse != undefined)
            {
               delScan = skse.GetLastKeycode(true);
            }

            if(delScan == this.NoteDeleteScan
               && (!this.NoteDeleteCtrl || Key.isDown(Key.CONTROL)))
            {
               this.OpenDeleteConfirm();
               return true;
            }

            if(details.navEquivalent == gfx.ui.NavigationCode.ENTER
               || details.navEquivalent == gfx.ui.NavigationCode.GAMEPAD_A)
            {
               this.EndEdit(true);
            }
            else if(details.navEquivalent == gfx.ui.NavigationCode.TAB)
            {
               this.FocusEditField(this.EditField == 0 ? 1 : 0);
               return true;
            }
            else if(details.navEquivalent == gfx.ui.NavigationCode.ESCAPE
                    || details.navEquivalent == gfx.ui.NavigationCode.GAMEPAD_B)
            {
               this.EndEdit(false);
               return true;
            }

            var next = pathToFocus.shift();
            if(next.handleInput(details, pathToFocus))
            {
               return true;
            }
         }

         return false;
      }

      if(Shared.GlobalFunc.IsKeyPressed(details))
      {
         // While the popup is open it owns the keyboard: anything that would
         // page the month behind it is swallowed, and only close gets through.
         // Returning true either way stops the key reaching the grid.
         if(this.Popup != undefined)
         {
            // The note key starts editing this day. Checked before the close
            // keys so it cannot be swallowed by them.
            //
            // Matched on the REAL scan code from skse.GetLastKeycode, so the
            // INI's NoteKey works whatever it is set to. N by default, not E:
            // E never reaches a custom menu -- the game consumes it before
            // Scaleform sees it -- so binding to it would look like the
            // feature simply not working.
            var noteScan = MessageBox.SCAN_UNKNOWN;
            if(skse != undefined)
            {
               noteScan = skse.GetLastKeycode(true);
            }

            if(noteScan == this.NoteKeyScan)
            {
               this.BeginEdit(this.PopupDay);
               return true;
            }

            if(details.code == this.KeyClose || details.code == this.KeyClosePad
               || details.navEquivalent == gfx.ui.NavigationCode.ESCAPE
               || details.navEquivalent == gfx.ui.NavigationCode.GAMEPAD_B
               || details.navEquivalent == gfx.ui.NavigationCode.ENTER
               || details.navEquivalent == gfx.ui.NavigationCode.GAMEPAD_A)
            {
               this.CloseDayPopup();
               gfx.io.GameDelegate.call("PlaySound", ["UIMenuCancel"]);
            }
            return true;
         }

         // A single if/else chain, matching CharacterSheet.handleInput.
         //
         // The keys are compared against values that were ALREADY converted
         // to VK codes in SetKeys -- converting per keystroke instead was the
         // bug that kept this from working. Both the keyboard and the gamepad
         // binding are tested on every branch, exactly as
         // `details.code == this.navLeftGamepadKey || details.code == this.navLeftKey`
         // does, so one code path serves both devices and there is no
         // platform flag to get out of step.
         if(details.code == this.KeyPrev || details.code == this.KeyPrevPad)
         {
            this.RequestMonth(-1);
            handled = true;
         }
         else if(details.code == this.KeyNext || details.code == this.KeyNextPad)
         {
            this.RequestMonth(1);
            handled = true;
         }
         else if(details.code == this.KeyToday || details.code == this.KeyTodayPad)
         {
            this.RequestMonth(0);
            handled = true;
         }
         else if(details.code == this.KeyClose || details.code == this.KeyClosePad
                 || details.navEquivalent == gfx.ui.NavigationCode.ESCAPE
                 || details.navEquivalent == gfx.ui.NavigationCode.GAMEPAD_B)
         {
            gfx.io.GameDelegate.call("CloseMenu", []);
            handled = true;
         }
         // Enter / A opens the selected day. Days with no events do nothing,
         // so this is a no-op on an empty square rather than an empty panel.
         else if(details.navEquivalent == gfx.ui.NavigationCode.ENTER
                 || details.navEquivalent == gfx.ui.NavigationCode.GAMEPAD_A)
         {
            if(this.SelectedIndex >= 0)
            {
               this.OpenDayPopup(this.Data.days[this.SelectedIndex]);
            }
            handled = true;
         }
         else if(details.navEquivalent == gfx.ui.NavigationCode.LEFT)
         {
            this.MoveSelection(-1);
            handled = true;
         }
         else if(details.navEquivalent == gfx.ui.NavigationCode.RIGHT)
         {
            this.MoveSelection(1);
            handled = true;
         }
         else if(details.navEquivalent == gfx.ui.NavigationCode.UP)
         {
            this.MoveSelection(-MessageBox.COLS);
            handled = true;
         }
         else if(details.navEquivalent == gfx.ui.NavigationCode.DOWN)
         {
            this.MoveSelection(MessageBox.COLS);
            handled = true;
         }
      }

      if(!handled && pathToFocus != undefined && pathToFocus.length > 0)
      {
         handled = pathToFocus[0].handleInput(details, pathToFocus.slice(1));
      }
      return handled;
   }

   // Moves the highlight by a whole number of cells, skipping the blanks
   // before the 1st and after the last day.
   function MoveSelection(aiDelta)
   {
      if(this.Data == undefined)
      {
         return;
      }

      var count = this.Data.days.length;

      // With nothing selected, the first move enters the grid at one end
      // rather than being measured from a stale index.
      if(this.SelectedIndex < 0)
      {
         this.SetSelection(aiDelta > 0 ? 0 : count - 1);
         gfx.io.GameDelegate.call("PlaySound", ["UIMenuFocus"]);
         return;
      }

      var next = this.SelectedIndex + aiDelta;
      if(next < 0 || next >= count)
      {
         return;
      }

      this.SetSelection(next);
      gfx.io.GameDelegate.call("PlaySound", ["UIMenuFocus"]);
   }

   // Drops the highlight without picking anything else. SelectedIndex goes to
   // -1, which MoveSelection treats as "no origin" so the first arrow press
   // lands on the 1st rather than jumping from a stale index.
   function ClearSelection()
   {
      if(this.SelectedIndex >= 0 && this.Cells[this.SelectedIndex] != undefined)
      {
         this.Cells[this.SelectedIndex].focused = 0;

         // Back to plain (or today) -- PaintCellFrame restores whichever from
         // the frame's own remembered flag.
         this.PaintCellFrame(this.SelectedIndex, false);
      }
      this.SelectedIndex = -1;

      // Focus must stay INSIDE this menu -- never null.
      //
      // FocusHandler.handleInput dispatches along getPathToFocus(), which
      // walks up the parent chain from the focused object. With focus null
      // that path is empty and handleInput is never called on us at all: the
      // mouse still worked (it does not need focus) but every key stopped
      // responding the moment a month changed. Vanilla MessageBox has the
      // same constraint and always focuses one of its buttons.
      //
      // The menu itself takes focus, so no day looks selected while keys keep
      // working.
      Selection.setFocus(this);

      // The detail line still names the month being viewed, so the panel does
      // not look broken when nothing is selected.
      this.DetailText.htmlText = this.Markup(
         this.FormatDate(undefined, this.Data.monthName, this.Data.year),
         MessageBox.FONT_SIZE_SMALL, true);
   }

   function SetSelection(aiIndex)
   {
      if(this.SelectedIndex >= 0 && this.Cells[this.SelectedIndex] != undefined)
      {
         this.Cells[this.SelectedIndex].focused = 0;
         this.PaintCellFrame(this.SelectedIndex, false);
      }

      this.SelectedIndex = aiIndex;

      var cell = this.Cells[aiIndex];
      if(cell != undefined)
      {
         cell.focused = 1;
         Selection.setFocus(cell);
         this.PaintCellFrame(aiIndex, true);
         this.ShowDetail(this.Data.days[aiIndex]);
      }
   }

   function RequestMonth(aiDelta)
   {
      gfx.io.GameDelegate.call("RequestMonth", [aiDelta]);
      gfx.io.GameDelegate.call("PlaySound", ["UIMenuPrevNext"]);
   }

   // ---- data ----------------------------------------------------------

   function SetCalendarData(aData)
   {
      this.Data = aData;
      this.SelectedIndex = -1;

      // A popup describes a day in the month being replaced, so it cannot
      // survive the swap. Reachable via the prompt buttons, which stay
      // clickable while it is open.
      this.CloseDayPopup();

      // Built here rather than in the constructor, and only once.
      //
      // The prompts are redrawn even when the bar already exists, because
      // their captions come from Data.labels. setKeys can arrive BEFORE the
      // first setCalendarData (it does, on the first open), and a bar drawn
      // then has no labels to read and falls back to English. Redrawing here
      // is what gets the translated captions onto a bar that was built early;
      // without it they would stay English for the rest of the session.
      if(this.PromptBar == undefined)
      {
         this.BuildPromptBar();
      }
      this.DrawPrompts();

      // BuildGrid sizes the cells and draws their frames, so the fitted
      // CELL_H has to be settled BEFORE it runs -- ResetDimensions at the end
      // of this function only repositions containers and would leave cells
      // built at the previous height. FitCellHeight is cheap and idempotent,
      // so calling it in both places is fine.
      this.FitCellHeight();
      this.BuildGrid();

      // The heading keeps MessageText's own vanilla format, so it alone would
      // render without a font tag -- but going through Markup keeps every
      // write consistent and matches the size the other fields use.
      this.HeadingText.htmlText =
         this.Markup(this.FormatDate(undefined, aData.monthName, aData.year),
                     MessageBox.FONT_SIZE, true);

      // The second line deliberately does NOT repeat the date. The heading
      // already names the month, the highlighted cell names the day, and the
      // Today button covers getting back -- so a full second date read as a
      // duplicate month line. It carries the season, the time, and whatever
      // is coming up next instead.
      var t = aData.today;
      var sub = aData.season + "   --   " + t.dayName + " "
              + this.Pad(t.hour) + ":" + this.Pad(t.minute);

      if(aData.next != undefined)
      {
         sub = sub + "   --   " + this.Label("next", "Next:") + " " + aData.next.name;
         sub = sub + " (" + this.FormatDaysAway(aData.next.daysAway) + ")";
      }

      this.TodayText.htmlText = this.Markup(sub, MessageBox.FONT_SIZE_SMALL, true);

      // Select today when the month contains it, and NOTHING otherwise.
      //
      // Defaulting to the 1st on other months implied a choice the player did
      // not make -- paging through the year left a highlight sitting on a
      // meaningless date. Cells stay clickable and the arrows still work; the
      // month simply opens with nothing picked.
      if(aData.month == t.month && aData.year == t.year)
      {
         this.SetSelection(t.day - 1);
      }
      else
      {
         this.ClearSelection();
      }

      this.ResetDimensions();
   }

   function Pad(n)
   {
      return n < 10 ? "0" + n : String(n);
   }

   // ---- text --------------------------------------------------------
   //
   // Every caption the menu draws comes from the plugin, in Data.labels, and
   // NOT from a literal here.
   //
   // This file is the one a UI replacer overrides, so a caption written into
   // it would be lost the moment somebody reskins the menu -- and translating
   // the mod would mean rebuilding the .swf with FFDec rather than editing a
   // text file. Keeping the words on the C++ side means one translation file
   // covers everything and a replacer only ever deals with the look.

   // A label by name, with an English fallback so the menu is still readable
   // if an old plugin build sends no labels at all.
   function Label(asName, asFallback)
   {
      if(this.Data == undefined || this.Data.labels == undefined)
      {
         return asFallback;
      }
      var value = this.Data.labels[asName];
      return (value == undefined || value.length == 0) ? asFallback : value;
   }

   // The display name for an event's kind: "holiday" -> "Holiday".
   //
   // The value on the event is the lowercase slug from the JSON, which is a
   // data contract and must not be translated. The label is a separate
   // Data.labels entry, so a translator changes what is shown without
   // touching what authors write in their files.
   //
   // A lookup object rather than a switch: AS2's switch compares with strict
   // equality and would not match reliably here, and an unknown kind should
   // fall back rather than throw the layout off.
   function KindLabel(asKind)
   {
      if(asKind == undefined || asKind.length == 0)
      {
         return "";
      }

      var map = { holiday:  this.Label("kindHoliday",  "Holiday"),
                  festival: this.Label("kindFestival", "Festival"),
                  history:  this.Label("kindHistory",  "History"),
                  note:     this.Label("kindNote",     "Note") };

      var label = map[asKind];

      // An unrecognised kind shows as authored rather than vanishing, which
      // makes a typo in someone's event file visible instead of silent.
      return label == undefined ? asKind : label;
   }

   // "17 Last Seed, 4E 201" -- the full date, in one place.
   //
   // The era ("4E") is a label rather than a literal for the same reason as
   // everything else: a total conversion set in another era needs to change
   // it, and should not have to rebuild the movie to do so.
   function FormatDate(aiDay, asMonthName, aiYear)
   {
      var era = this.Label("era", "4E");
      var date = asMonthName + ", " + era + " " + aiYear;
      return aiDay == undefined ? date : (aiDay + " " + date);
   }

   // "(today)" / "(tomorrow)" / "(in 5 days)".
   //
   // The day count is substituted into "{}" rather than concatenated, so a
   // language that puts the number elsewhere in the phrase can still write it
   // naturally.
   function FormatDaysAway(aiDays)
   {
      if(aiDays == 0)
      {
         return this.Label("onToday", "today");
      }
      if(aiDays == 1)
      {
         return this.Label("tomorrow", "tomorrow");
      }

      var pattern = this.Label("inDays", "in {} days");
      var at = pattern.indexOf("{}");
      if(at < 0)
      {
         // A translation that dropped the placeholder still gets a number.
         return pattern + " " + aiDays;
      }
      return pattern.substring(0, at) + aiDays + pattern.substring(at + 2);
   }

   // ---- the grid ------------------------------------------------------

   function BuildGrid()
   {
      if(this.CellContainer != undefined)
      {
         this.CellContainer.removeMovieClip();
      }
      if(this.HeaderContainer != undefined)
      {
         this.HeaderContainer.removeMovieClip();
      }
      if(this.FrameContainer != undefined)
      {
         this.FrameContainer.removeMovieClip();
      }
      this.Cells.length = 0;

      // Fixed depths, not getNextHighestDepth(). BuildGrid runs on every month
      // change, so allocating a fresh depth each time would climb without
      // bound as the player pages -- and would eventually overtake the nav
      // buttons, which are allocated once in the constructor.
      this.HeaderContainer = this.createEmptyMovieClip("Headers", MessageBox.DEPTH_HEADERS);
      this.FrameContainer = this.createEmptyMovieClip("Frames", MessageBox.DEPTH_FRAMES);
      this.CellContainer = this.createEmptyMovieClip("Cells", MessageBox.DEPTH_CELLS);

      var gridW = MessageBox.COLS * MessageBox.CELL_W
                + (MessageBox.COLS - 1) * MessageBox.CELL_GAP;
      var left = -gridW / 2;

      // Weekday headings.
      var i = 0;
      while(i < MessageBox.COLS)
      {
         var label = this.HeaderContainer.createTextField(
            "wd" + i, i, left + i * (MessageBox.CELL_W + MessageBox.CELL_GAP),
            0, MessageBox.CELL_W, 22);
         label.selectable = false;
         label.html = true;
         label.htmlText = this.Markup(
            String(this.Data.dayNames[i]).toUpperCase(),
            MessageBox.FONT_SIZE_SMALL, true);
         i = i + 1;
      }

      // Day cells. Each is a MessageBoxButton, so it comes with the vanilla
      // focus highlight and selection indicator rather than a drawn one.
      var days = this.Data.days;
      var col = days.length > 0 ? days[0].weekday : 0;
      var row = 0;
      var self = this;

      i = 0;
      while(i < days.length)
      {
         var day = days[i];

         var cell = gfx.controls.Button(this.CellContainer.attachMovie(
            "MessageBoxButton", "day" + i, this.CellContainer.getNextHighestDepth()));

         cell._x = left + col * (MessageBox.CELL_W + MessageBox.CELL_GAP)
                 + MessageBox.CELL_W / 2;
         cell._y = row * (MessageBox.CELL_H + MessageBox.CELL_GAP)
                 + MessageBox.CELL_H / 2;

         // setSize, not _width/_height. gfx.core.UIComponent caches its size
         // in __width/__height and Button.draw() writes those back over
         // _width/_height on the next redraw, so a direct assignment is
         // undone the moment the button changes state. setSize updates the
         // cache and runs the Constraints that resize ButtonText with it.
         cell.setSize(MessageBox.CELL_W, MessageBox.CELL_H);

         // Hide the vanilla selection art -- the drawn frame shows selection
         // now, and the two together read as clutter. _visible rather than
         // removing it: it is a timeline child that the button's own state
         // frames re-place, so removal would not stick.
         if(cell.SelectionIndicatorHolder != undefined)
         {
            cell.SelectionIndicatorHolder._visible = false;
         }

         // Stretch the clickable region to the whole cell.
         //
         // MessageBoxButton's frame 1 does `this.hitArea = this.HitArea`,
         // pointing at a shape authored for the vanilla message-box button.
         // setSize() does NOT resize it -- it is not part of the Constraints,
         // which only cover ButtonText -- so every cell kept a hit region the
         // size and shape of the original button, centred in the middle of
         // the square. Clicks near a cell's edges landed on nothing.
         //
         // Sized rather than replaced: the shape is already the hitArea and
         // is invisible (the vanilla art relies on that), so resizing it is
         // enough and needs no new symbol in the SWF.
         if(cell.HitArea != undefined)
         {
            cell.HitArea._width = MessageBox.CELL_W;
            cell.HitArea._height = MessageBox.CELL_H;
            cell.HitArea._x = -MessageBox.CELL_W / 2;
            cell.HitArea._y = -MessageBox.CELL_H / 2;
         }

         var text = cell.ButtonText;
         text.autoSize = "none";
         text.html = true;
         text.noTranslate = true;

         // wordWrap on, and sized to the cell. Without both, a long event
         // name renders as one unbroken line straight across its neighbours
         // rather than wrapping under the day number.
         text.wordWrap = true;
         text.multiline = true;
         text._width = MessageBox.CELL_W;
         text._x = -MessageBox.CELL_W / 2;

         // _y is set explicitly now that the cell is taller than the button
         // art it came from. ButtonText's authored position is centred for a
         // 55px plate, so in an 80px box it would float above the middle and
         // sit off-centre inside the drawn frame. Pinning it near the top
         // also gives the event name the room below the day number.
         text._height = MessageBox.CELL_H - 8;
         text._y = -MessageBox.CELL_H / 2 + 4;

         // Today is marked in the text itself, since the cell art is shared
         // with every other button.
         // The day number, with an event name under it when there is one.
         // Both go through Markup: SetText replaces the field's contents
         // wholesale, so the font has to travel with the markup.
         var mark = this.Markup(
            day.isToday ? "<b>" + day.day + "</b>" : String(day.day),
            MessageBox.FONT_SIZE, true);

         if(day.events.length > 0)
         {
            mark = mark + this.Markup(day.events[0].name,
                                      MessageBox.FONT_SIZE_EVENT, true);
         }
         text.SetText(mark, true);

         // The square, drawn behind the button at the same centre.
         this.DrawCellFrame(i, cell._x, cell._y, day.isToday, day.moon);

         cell.disableFocus = false;
         cell.CellIndex = i;

         cell.addEventListener("press", this, "onCellPress");
         cell.addEventListener("focusIn", this, "onCellFocus");
         cell.addEventListener("rollOver", this, "onCellFocus");

         this.Cells.push(cell);

         col = col + 1;
         if(col >= MessageBox.COLS)
         {
            col = 0;
            row = row + 1;
         }
         i = i + 1;
      }
   }

   // One day's box: a filled rectangle with a border, drawn into its own clip
   // inside FrameContainer.
   //
   // aiX/aiY are the CELL'S CENTRE, because a MessageBoxButton's origin is its
   // centre and the frame has to line up with the button it sits behind -- so
   // the rectangle is drawn from -W/2,-H/2 and the clip is moved to the centre,
   // rather than drawing at a top-left corner.
   //
   // moveTo/lineTo rather than drawRect: AS2's drawing API has no rectangle
   // primitive, so the four sides are walked by hand.
   // The clip is created once and REDRAWN on selection changes, so it keeps a
   // fixed name and its own remembered "is today" flag -- PaintCellFrame
   // needs that to restore the right look when selection moves away.
   function DrawCellFrame(aiIndex, aiX, aiY, abToday, aiMoon)
   {
      var frame = this.FrameContainer.createEmptyMovieClip(
         "frame" + aiIndex, aiIndex);

      frame._x = aiX;
      frame._y = aiY;
      frame.IsToday = abToday;

      // Remembered on the clip alongside IsToday, and for the same reason:
      // PaintCellFrame clears and redraws on every selection change, so it
      // needs to know what to put back without going to the data again.
      //
      // undefined means "no phase on this day" -- C++ omits the member rather
      // than sending a sentinel, so the absence carries through unchanged.
      frame.MoonPhase = aiMoon;

      this.PaintCellFrame(aiIndex, false);
   }

   // Paint one frame in its current state.
   //
   // Three looks, in priority order: selected (bright white, thick), today
   // (gold, thick), plain (muted gold, hairline, low alpha). Selection wins
   // over today because it is the thing the player is actively moving; a
   // today cell that is also selected still reads as today by keeping the
   // thicker border.
   //
   // clear() first, because a redraw would otherwise stack a second rectangle
   // on the first -- and a thin old border showing through a new one looks
   // like a rendering fault rather than a state.
   function PaintCellFrame(aiIndex, abSelected)
   {
      var frame = this.FrameContainer["frame" + aiIndex];
      if(frame == undefined)
      {
         return;
      }

      frame.clear();

      var w = MessageBox.CELL_W;
      var h = MessageBox.CELL_H;
      var l = -w / 2;
      var t = -h / 2;

      var lineColor;
      var lineAlpha;
      var lineWidth;

      if(abSelected)
      {
         lineColor = MessageBox.SELECTION_COLOR;
         lineAlpha = MessageBox.SELECTION_ALPHA;
         lineWidth = MessageBox.SELECTION_LINE;
      }
      else if(frame.IsToday)
      {
         lineColor = MessageBox.FRAME_TODAY_COLOR;
         lineAlpha = MessageBox.FRAME_TODAY_ALPHA;
         lineWidth = MessageBox.TODAY_LINE;
      }
      else
      {
         lineColor = MessageBox.FRAME_LINE_COLOR;
         lineAlpha = MessageBox.FRAME_LINE_ALPHA;
         lineWidth = MessageBox.FRAME_LINE;
      }

      frame.lineStyle(lineWidth, lineColor, lineAlpha);
      frame.beginFill(MessageBox.FRAME_FILL_COLOR, MessageBox.FRAME_FILL_ALPHA);
      frame.moveTo(l, t);
      frame.lineTo(l + w, t);
      frame.lineTo(l + w, t + h);
      frame.lineTo(l, t + h);
      frame.lineTo(l, t);
      frame.endFill();

      // The moon last, so it sits over the cell fill rather than under it.
      // Redrawn here rather than in DrawCellFrame because the clear() above
      // takes it with the border -- it has to go back on every repaint.
      if(frame.MoonPhase != undefined)
      {
         this.DrawMoon(frame, frame.MoonPhase);
      }
   }

   // --- Moon phases -------------------------------------------------------
   //
   // Drawn with the drawing API rather than attached as artwork, for the same
   // reason the cell frames are: no new symbol has to be authored into the
   // SWF, so the phases survive the FFDec injection step untouched and a UI
   // replacer inherits them without having to hold the assets.
   //
   // AS2 has no circle primitive -- and no arc -- so everything below is built
   // from quadratic beziers, which is what the drawing API's curveTo takes.

   // How many bezier segments make up one quarter turn.
   //
   // Two. A single quadratic over 90 degrees bows visibly off the circle;
   // splitting it in half brings the worst-case radial error at MOON_R down to
   // about 0.02px, which is far below a pixel and so invisible. More segments
   // would cost draw calls for an error already well under what can be seen.
   static var ARC_SEGMENTS = 2;

   // Walks a quarter turn of a circle centred on (aiCX, aiCY), from angle
   // aiFrom to aiFrom + aiSweep radians. Assumes the pen is already at the
   // start point -- the callers below all move or draw into position first,
   // which is what lets these be chained into a closed outline.
   // aiRX and aiRY are separate radii, so this walks an ELLIPSE as readily as
   // a circle. That is what the terminator needs: the shadow boundary on a
   // sphere projects to a half-ellipse whose width shrinks to nothing at the
   // quarters, and passing aiRX == aiRY is just the circular case of it.
   function ArcTo(aClip, aiCX, aiCY, aiRX, aiRY, aiFrom, aiSweep)
   {
      var steps = MessageBox.ARC_SEGMENTS;
      var step = aiSweep / steps;
      var i = 0;
      while(i < steps)
      {
         var a0 = aiFrom + step * i;
         var a1 = a0 + step;

         // The control point sits where the tangents at the two ends meet.
         // That is the arc's midpoint pushed out by 1/cos(half the sweep),
         // which is what makes the curve pass through the arc rather than
         // cutting the chord. Scaling x and y independently afterwards turns
         // the circle into the ellipse without disturbing that.
         var mid = (a0 + a1) / 2;
         var scale = 1 / Math.cos((a1 - a0) / 2);

         aClip.curveTo(aiCX + Math.cos(mid) * aiRX * scale,
                       aiCY + Math.sin(mid) * aiRY * scale,
                       aiCX + Math.cos(a1) * aiRX,
                       aiCY + Math.sin(a1) * aiRY);
         i = i + 1;
      }
   }

   // A full circle, as a closed path. Used for the dark body and for the
   // full moon's lit face.
   function DrawDisc(aClip, aiCX, aiCY, aiR)
   {
      aClip.moveTo(aiCX + aiR, aiCY);
      this.ArcTo(aClip, aiCX, aiCY, aiR, aiR, 0, Math.PI / 2);
      this.ArcTo(aClip, aiCX, aiCY, aiR, aiR, Math.PI / 2, Math.PI / 2);
      this.ArcTo(aClip, aiCX, aiCY, aiR, aiR, Math.PI, Math.PI / 2);
      this.ArcTo(aClip, aiCX, aiCY, aiR, aiR, Math.PI * 3 / 2, Math.PI / 2);
   }

   // Half a disc: the lit face of a quarter moon.
   //
   // abRightLit picks which side is lit. First quarter is lit on the right as
   // the moon waxes; third quarter on the left as it wanes. Drawn as a
   // half-circle closed by its own diameter, so it needs no mask -- a mask
   // would mean a second clip per cell and 31 more of them per month.
   // The lit part of a moon at any phase, as one closed path.
   //
   // Every phase has the same two boundaries:
   //
   //   * the LIMB -- the outer edge of the disc on the lit side, always a
   //     semicircle of radius aiR;
   //   * the TERMINATOR -- the shadow boundary running pole to pole. On a
   //     sphere this is a circle seen edge-on, so it projects to a half
   //     ellipse: full width at new and full moon, and pinched to a straight
   //     line at the quarters.
   //
   // aiK is where the terminator sits, -1 to +1: the fraction of the disc lit
   // is (1 + aiK) / 2, so -1 is new, 0 is a quarter, +1 is full. Its SIGN is
   // what separates a crescent from a gibbous -- negative and the ellipse
   // bulges into the lit side, eating it away to a sliver; positive and it
   // bulges the other way, leaving all but a sliver.
   //
   // Building the lune this way means one path per phase and no masking. A
   // mask would need a second clip for every cell, and 31 of those a month is
   // exactly the kind of thing that makes a menu feel heavy.
   function DrawLune(aClip, aiCX, aiCY, aiR, abRightLit, aiK)
   {
      // Start at the top pole, round the lit limb to the bottom pole, then
      // back up the terminator to close.
      var sign = abRightLit ? 1 : -1;
      var from = abRightLit ? -Math.PI / 2 : Math.PI / 2;
      var startY = aiCY - sign * aiR;

      aClip.moveTo(aiCX, startY);

      // The limb: two quarter turns down the lit side.
      this.ArcTo(aClip, aiCX, aiCY, aiR, aiR, from, Math.PI / 2);
      this.ArcTo(aClip, aiCX, aiCY, aiR, aiR, from + Math.PI / 2, Math.PI / 2);

      // The terminator, back the other way.
      //
      // The x-radius is NOT multiplied by `sign`. The terminator arc is
      // already being walked from the dark side (angles from + PI onwards),
      // so the sweep direction alone puts it on the correct side; folding
      // `sign` in as well would cancel that out and mirror the bulge, which
      // renders a waning gibbous as a crescent and vice versa.
      //
      // aiK's own sign is what flips the bulge: negative eats into the lit
      // side (crescent), positive leaves all but a sliver (gibbous). At
      // aiK == 0 the radius is zero and the two arcs collapse onto the
      // straight diameter of a quarter moon.
      var rx = aiR * aiK;
      this.ArcTo(aClip, aiCX, aiCY, rx, aiR, from + Math.PI, Math.PI / 2);
      this.ArcTo(aClip, aiCX, aiCY, rx, aiR, from + Math.PI * 3 / 2, Math.PI / 2);
   }

   // The moon marker for one cell.
   //
   // Drawn into the cell's own frame clip rather than a clip of its own: the
   // frame is already positioned at the cell centre, is already cleared and
   // repainted on every selection change, and is torn down with the grid. A
   // separate clip would need all three of those handled again, and would be
   // one more thing to keep in step with PaintCellFrame.
   //
   // That does mean this MUST be called from PaintCellFrame, after its clear()
   // -- which is exactly where it is called from.
   function DrawMoon(aClip, aiPhase)
   {
      // Top-right corner of the cell. The clip's origin is the cell centre,
      // so the corner is +W/2, -H/2 and the inset walks back in from there.
      var cx = MessageBox.CELL_W / 2 - MessageBox.MOON_INSET;
      var cy = -MessageBox.CELL_H / 2 + MessageBox.MOON_INSET;
      var r = MessageBox.MOON_R;

      // The dark body first, so every phase sits on the same disc and the
      // outline is unbroken whatever is lit on top of it.
      aClip.lineStyle(MessageBox.MOON_EDGE_LINE, MessageBox.MOON_EDGE_COLOR,
                      MessageBox.MOON_EDGE_ALPHA);
      aClip.beginFill(MessageBox.MOON_DARK_COLOR, MessageBox.MOON_DARK_ALPHA);
      this.DrawDisc(aClip, cx, cy, r);
      aClip.endFill();

      // A new moon is the dark body alone -- nothing lit to add.
      if(aiPhase == MessageBox.MOON_NEW)
      {
         return;
      }

      // The lit part, drawn without a line so it does not double the outline
      // already around the body.
      aClip.lineStyle(undefined);
      aClip.beginFill(MessageBox.MOON_LIT_COLOR, MessageBox.MOON_LIT_ALPHA);

      if(aiPhase == MessageBox.MOON_FULL)
      {
         this.DrawDisc(aClip, cx, cy, r);
      }
      else
      {
         // Everything between new and full is a lune: which side is lit, and
         // how far across it the terminator has travelled.
         //
         // WAXING phases are lit on the right and WANING on the left, which is
         // the northern-hemisphere convention and the one the game's own moon
         // textures follow -- the icon should not disagree with the sky.
         //
         // The k values are the quarter points of the cycle: -0.5 is a
         // quarter lit (crescent), 0 is half (quarter moon), +0.5 is three
         // quarters (gibbous). See DrawLune -- lit fraction is (1 + k) / 2.
         var rightLit = aiPhase == MessageBox.MOON_WAXING_CRESCENT
                     || aiPhase == MessageBox.MOON_FIRST_QUARTER
                     || aiPhase == MessageBox.MOON_WAXING_GIBBOUS;

         var k = 0;
         if(aiPhase == MessageBox.MOON_WAXING_CRESCENT
         || aiPhase == MessageBox.MOON_WANING_CRESCENT)
         {
            k = -MessageBox.MOON_LUNE_K;
         }
         else if(aiPhase == MessageBox.MOON_WAXING_GIBBOUS
              || aiPhase == MessageBox.MOON_WANING_GIBBOUS)
         {
            k = MessageBox.MOON_LUNE_K;
         }

         this.DrawLune(aClip, cx, cy, r, rightLit, k);
      }

      aClip.endFill();
   }

   function onCellPress(event)
   {
      this.SetSelection(event.target.CellIndex);
      this.OpenDayPopup(this.Data.days[event.target.CellIndex]);
   }

   function onCellFocus(event)
   {
      var idx = event.target.CellIndex;
      if(idx != undefined)
      {
         this.ShowDetail(this.Data.days[idx]);
      }
   }

   // ---- the prompt bar ------------------------------------------------
   //
   // Modelled on how Character Menu SE (charactersheet.swf) does it, which is
   // in turn SkyUI's skyui.components.ButtonPanel pattern.
   //
   // The icons are frames of "ButtonArt", a sprite imported from SkyUI's
   // interface/skyui/buttonart.swf and indexed *by DX scan code*:
   //
   //     frames 1-255    keyboard      (Q=16, E=18, R=19, Esc=1, Tab=15)
   //     frames 256-265  mouse
   //     frames 266+     gamepad       (A=276, B=277, LB=274, RB=275, Y=279)
   //
   // so drawing the right glyph is just gotoAndStop(scanCode) -- no text, no
   // per-platform art of our own. That is why this needs no [Q]-style
   // fallback: the strip already contains every key and button the game
   // knows about, in both keyboard and gamepad flavours.
   //
   // The scan codes come from the plugin (SetKeys) rather than being fixed
   // here, so a rebind in the INI moves both the binding and its icon
   // together and the two cannot disagree.
   function BuildPromptBar()
   {
      this.PromptBar = this.createEmptyMovieClip("Prompts", MessageBox.DEPTH_PROMPTS);
      this.Prompts = new Array();
   }

   // One prompt: the key's icon followed by its caption.
   function AddPrompt(aiScanCode, asLabel, asHandler)
   {
      var i = this.Prompts.length;
      var holder = this.PromptBar.createEmptyMovieClip("p" + i, i);

      var icon = holder.attachMovie("ButtonArt", "icon", 1);
      icon.gotoAndStop(aiScanCode);

      // The caption is offset by the icon's ACTUAL width, not a constant.
      // ButtonArt glyphs are not all the same size -- a key cap like "Esc" is
      // much wider than a single letter -- so a fixed offset left the wide
      // ones crowding, and overlapping, their own label.
      var label = holder.createTextField(
         "cap", 2, icon._width + MessageBox.PROMPT_ICON_GAP, 0, 200, 24);
      label.selectable = false;
      label.html = true;
      label.noTranslate = true;
      label.autoSize = "left";
      label.htmlText = this.Markup(asLabel, MessageBox.FONT_SIZE_HINT, false);

      // Sit the caption on the icon's centre line. Icon heights vary with the
      // glyph just as widths do, so this is measured too.
      label._y = (icon._height - label._height) / 2;

      // Clickable as well as bound to a key. The prompt IS the button --
      // there is no separate on-screen control -- so the whole clip takes the
      // press, using onRelease rather than an "click" listener because these
      // are plain MovieClips, not gfx.controls.Button instances.
      if(asHandler != undefined)
      {
         holder.onRollOver = function()
         {
            this._alpha = 60;
         };
         holder.onRollOut = function()
         {
            this._alpha = 100;
         };
         holder.onRelease = function()
         {
            this._alpha = 100;

            // Hand focus back to the menu before acting: the action may
            // rebuild the grid, and focus must stay inside this menu or
            // handleInput stops being dispatched to us.
            Selection.setFocus(this.Owner);
            this.Owner[this.Handler]();
         };

         holder.Owner = this;
         holder.Handler = asHandler;

         // A clip with an onRelease is a button as far as AS2 is concerned,
         // and a button takes focus when clicked. That would move focus out
         // of the menu and off the path FocusHandler dispatches along, so
         // every key would stop working after the first click on a prompt --
         // mouse still fine, keyboard dead. Refusing focus keeps the prompts
         // clickable without ever owning it.
         holder.focusEnabled = false;
         holder.tabEnabled = false;

         // A transparent fill across the whole prompt, so the gap between the
         // icon and its caption is clickable too. An empty clip only takes
         // mouse events where something is actually drawn, which would leave
         // the row full of dead strips.
         // Width is captured BEFORE drawing: the fill becomes part of the
         // clip, so reading _width mid-draw would feed back on itself.
         var hitW = holder._width;

         holder.beginFill(0x000000, 0);
         holder.moveTo(0, 0);
         holder.lineTo(hitW, 0);
         holder.lineTo(hitW, MessageBox.PROMPT_HIT_H);
         holder.lineTo(0, MessageBox.PROMPT_HIT_H);
         holder.endFill();

         holder.useHandCursor = true;
      }

      this.Prompts.push(holder);
      return holder;
   }

   // What the prompts do when clicked. The same actions the keys trigger, so
   // the two can never diverge.
   function onPromptPrev()  { this.RequestMonth(-1); }
   function onPromptNext()  { this.RequestMonth(1); }
   function onPromptToday() { this.RequestMonth(0); }

   // No onPromptClose: the Close prompt was removed as redundant (Esc/B
   // closes every menu in the game). Escape itself is still handled in
   // handleInput -- only the on-screen label is gone. The close scan codes
   // are still sent by the plugin and kept in PendingKeys, so restoring the
   // prompt would be a one-line AddPrompt and nothing else.

   // Lays the prompts out in a centred row. Widths are measured rather than
   // assumed, the way ButtonPanel.doUpdateButtons does, because a caption's
   // width depends on the font the player's UI replacer supplies.
   function LayoutPrompts()
   {
      var total = 0;
      var i = 0;
      while(i < this.Prompts.length)
      {
         total = total + this.Prompts[i]._width + MessageBox.PROMPT_GAP;
         i = i + 1;
      }
      total = total - MessageBox.PROMPT_GAP;

      var x = -total / 2;
      i = 0;
      while(i < this.Prompts.length)
      {
         this.Prompts[i]._x = x;
         x = x + this.Prompts[i]._width + MessageBox.PROMPT_GAP;
         i = i + 1;
      }
   }

   // Called by the plugin with the scan codes it is actually listening for.
   // Keyboard and gamepad codes arrive together; which set is drawn depends
   // on abGamepad, exactly as CharacterSheet.SetGamepad does it.
   // The editor's key bindings, from the INI via the plugin.
   //
   // Stored as SCAN codes and compared against skse.GetLastKeycode(), not
   // converted to VK like the month keys above -- inside a focused text field
   // the game's binding layer rewrites VK values and they cannot be told
   // apart. See onKeyDown.
   function SetNoteKeys(aiNote, aiSave, aiCancel, aiSwitch, aiDelete, abDeleteCtrl)
   {
      this.NoteKeyScan = Number(aiNote);
      this.NoteSaveScan = Number(aiSave);
      this.NoteCancelScan = Number(aiCancel);
      this.NoteSwitchScan = Number(aiSwitch);
      this.NoteDeleteScan = Number(aiDelete);
      this.NoteDeleteCtrl = abDeleteCtrl;
   }

   function SetKeys(abGamepad, aiPrev, aiNext, aiToday, aiPrevPad, aiNextPad,
                    aiTodayPad, aiClose, aiClosePad)
   {
      this.bGamepad = abGamepad;

      // Convert to VK codes ONCE, here, exactly as CharacterSheet.SetGamepad
      // does -- handleInput then compares details.code directly against
      // these. Converting inside the comparison instead is what kept the
      // bindings from ever matching.
      //
      // Recorded before anything that can fail: setKeys arrives from the
      // plugin *before* setCalendarData, so on the first open PromptBar does
      // not exist yet and the drawing below is a no-op. The bindings still
      // have to be stored, or no key works until the player pages the month.
      this.KeyPrev = MessageBox.ScanToVK(aiPrev);
      this.KeyNext = MessageBox.ScanToVK(aiNext);
      this.KeyToday = MessageBox.ScanToVK(aiToday);
      this.KeyClose = MessageBox.ScanToVK(aiClose);

      this.KeyPrevPad = MessageBox.ScanToVK(aiPrevPad);
      this.KeyNextPad = MessageBox.ScanToVK(aiNextPad);
      this.KeyTodayPad = MessageBox.ScanToVK(aiTodayPad);
      this.KeyClosePad = MessageBox.ScanToVK(aiClosePad);

      // The confirmation window keeps its arrow icons on both devices: the
      // d-pad and the arrow keys do the same thing there, so there is nothing
      // to swap. (The month prompts still swap, because their face buttons
      // genuinely differ from their keys.)

      // Held so the bar can be drawn later, once BuildPromptBar has run.
      this.PendingKeys = { gamepad: abGamepad,
                           prev:  abGamepad ? aiPrevPad  : aiPrev,
                           next:  abGamepad ? aiNextPad  : aiNext,
                           today: abGamepad ? aiTodayPad : aiToday,
                           close: abGamepad ? aiClosePad : aiClose };

      if(this.PromptBar == undefined)
      {
         return;
      }

      this.DrawPrompts();
   }

   // Draws the prompt row from PendingKeys. Separate from SetKeys because the
   // two happen at different times on the first open.
   function DrawPrompts()
   {
      if(this.PromptBar == undefined || this.PendingKeys == undefined)
      {
         return;
      }

      var k = this.PendingKeys;

      // Rebuilt wholesale rather than patched: the caption set differs
      // between the two platforms (a gamepad has no Esc), so there is no
      // stable slot-to-prompt mapping to update in place.
      var j = 0;
      while(j < this.Prompts.length)
      {
         this.Prompts[j].removeMovieClip();
         j = j + 1;
      }
      this.Prompts = new Array();

      // Prev / Today / Next, in that reading order -- Today sits between the
      // two it steps back to, rather than off at one end.
      //
      // Close is deliberately NOT here. Escape (and B on a pad) closes every
      // menu in the game, so labelling it taught nobody anything and cost a
      // quarter of the bar. The binding itself is unchanged; only the prompt
      // is gone.
      this.AddPrompt(k.prev,  this.Label("prevMonth", "Prev Month"), "onPromptPrev");
      this.AddPrompt(k.today, this.Label("today",     "Today"),      "onPromptToday");
      this.AddPrompt(k.next,  this.Label("nextMonth", "Next Month"), "onPromptNext");

      this.LayoutPrompts();
   }

   // The description panel under the grid.
   function ShowDetail(aDay)
   {
      if(aDay == undefined)
      {
         this.DetailText.htmlText = "";
         return;
      }

      // Line 1: the date, plus the day's holiday names.
      // Line 2: the first holiday's description.
      //
      // Deliberately split rather than run together and left to wrap where it
      // falls. The field is two lines high and does not grow, so putting the
      // date and name on their own line guarantees the part worth reading is
      // always visible -- only the tail of a long description is ever lost.
      var head = this.FormatDate(aDay.day, this.Data.monthName, this.Data.year);
      var body = "";

      // The moon, when the day is marked. On the head line next to the date,
      // because that is what the icon in the cell is a shorthand FOR -- the
      // player looking at a gold disc in a corner should be able to find out
      // what it means without opening anything.
      //
      // The name is sent from C++ already translated, so nothing here maps a
      // phase number onto a word.
      if(aDay.moonName != undefined && aDay.moonName.length > 0)
      {
         head = head + "   " + aDay.moonName;
      }

      if(aDay.events.length > 0)
      {
         var names = "";
         var i = 0;
         while(i < aDay.events.length)
         {
            names = names + (i > 0 ? ", " : "") + aDay.events[i].name;
            i = i + 1;
         }
         head = head + "   <b>" + names + "</b>";

         // The kind goes on the head line, not the body: the body is the
         // description and this field is only two lines high, so spending a
         // whole line on one word would cost the text worth reading. Only
         // shown for a single event -- with several on a day the kinds may
         // differ and one label could not honestly stand for all of them.
         if(aDay.events.length == 1)
         {
            var kind = this.KindLabel(aDay.events[0].kind);
            if(kind.length > 0)
            {
               head = head + "   (" + kind + ")";
            }
         }

         // Only the first description: with two lines there is no room for
         // more, and a day with several holidays is rare.
         body = aDay.events[0].description;
      }

      this.DetailText.html = true;
      this.DetailText.htmlText = this.Markup2(head, MessageBox.FONT_SIZE_SMALL,
                                              body, MessageBox.FONT_SIZE_HINT);
   }

   // ---- the day popup -------------------------------------------------
   //
   // Opened by pressing Enter/A on a day, or clicking one. Days with no
   // events do nothing at all -- pressing Enter on an empty square should not
   // produce a dead-end panel with nothing in it.
   //
   // The panel is "CalendarPanel", the base movie's own Background_mc
   // (sprite 11) exported by the build. It carries a DefineScalingGrid, so
   // setting _width/_height 9-slices the border correctly at any size and the
   // popup can grow to fit its text.
   function OpenDayPopup(aDay)
   {
      // An empty day still opens.
      //
      // It used to return here, because a popup with nothing in it was just a
      // blank box. Now it is where a note is added, so opening a day with no
      // events is the normal way to write one -- and refusing would make the
      // commonest case unreachable.
      if(aDay == undefined)
      {
         return;
      }

      this.CloseDayPopup();

      // A child of the menu, so the focus path still reaches our handleInput.
      // Attached to _root instead, every key would stop working while it was
      // open.
      this.Popup = this.createEmptyMovieClip("DayPopup", MessageBox.DEPTH_POPUP);
      this.PopupDay = aDay;

      var panel = this.Popup.attachMovie("CalendarPanel", "panel", 1);

      var innerW = MessageBox.POPUP_W - MessageBox.POPUP_PAD * 2;
      var textLeft = -innerW / 2;

      // Heading: the full date.
      var head = this.Popup.createTextField("head", 2, textLeft, 0, innerW, 30);
      head.selectable = false;
      head.html = true;
      head.noTranslate = true;
      head.wordWrap = true;
      head.multiline = true;
      head.autoSize = "left";
      head.htmlText = this.Markup(
         this.FormatDate(aDay.day, this.Data.monthName, this.Data.year),
         MessageBox.FONT_SIZE, true);

      // Body: every event on the day, name then description.
      var body = this.Popup.createTextField("body", 3, textLeft, 0, innerW, 30);
      body.selectable = false;
      body.html = true;
      body.noTranslate = true;
      body.wordWrap = true;
      body.multiline = true;
      body.autoSize = "left";

      var out = "";
      var i = 0;
      while(i < aDay.events.length)
      {
         var e = aDay.events[i];
         if(i > 0)
         {
            out = out + "<br/><br/>";
         }
         out = out + this.Markup("<b>" + e.name + "</b>",
                                 MessageBox.FONT_SIZE_SMALL, true);

         // The kind on its own line under the name, at the smaller size, so
         // it reads as a label for the entry rather than part of the title.
         var kind = this.KindLabel(e.kind);
         if(kind.length > 0)
         {
            out = out + "<br/>" + this.Markup(kind, MessageBox.FONT_SIZE_HINT, true);
         }

         if(e.description.length > 0)
         {
            out = out + "<br/>" + this.Markup(e.description,
                                              MessageBox.FONT_SIZE_HINT, true);
         }
         i = i + 1;
      }

      // How to add or change the note. Always shown, including on a day with
      // no events at all -- that is the empty popup's only content, and
      // without it the box would look broken rather than inviting.
      if(out.length > 0)
      {
         out = out + "<br/><br/>";
      }
      body.htmlText = this.MarkupBlock(out);

      // Height comes from the text, measured after it is set. autoSize keeps
      // _height honest, so nothing here has to guess at a line count.
      // The note prompt: icon + caption, clickable, under the body text.
      //
      // A prompt rather than a line of prose, so it matches the month prompts
      // and the editor's own bar -- and so a mouse player can open the editor
      // at all. Built before contentH is measured, because it adds to the
      // height the panel has to cover.
      this.PopupPrompts = new Array();
      var pbar = this.Popup.createEmptyMovieClip("pbar", 6);
      this.PopupPromptBar = pbar;

      this.AddEditPrompt(
         pbar, this.PopupPrompts, this.NoteKeyScan,
         this.FindNote(aDay) != undefined ? this.Label("noteEdit2", "Edit note")
                                          : this.Label("noteAdd", "Add note"),
         "OnPromptAddNote");

      // Centred on the panel.
      pbar._x = -pbar._width / 2;

      var contentH = head._height + 12 + body._height
                   + MessageBox.POPUP_PROMPT_H;
      var panelH = contentH + MessageBox.POPUP_PAD * 2;
      if(panelH < MessageBox.POPUP_MIN_H)
      {
         panelH = MessageBox.POPUP_MIN_H;
      }

      // And a ceiling, because this height is MEASURED from the text.
      //
      // A day carrying several events with long descriptions could otherwise
      // grow the panel past the stage and clip top and bottom -- the same way
      // the grid did before FitCellHeight. The body text is clipped instead of
      // the frame, which at least leaves a window that looks deliberate.
      var maxH = MessageBox.STAGE_H - MessageBox.SCREEN_PAD * 2;
      if(panelH > maxH)
      {
         panelH = maxH;
         body._height = panelH - MessageBox.POPUP_PAD * 2 - head._height - 12;
      }

      panel._width = MessageBox.POPUP_W;
      panel._height = panelH;

      var top = -panelH / 2 + MessageBox.POPUP_PAD;
      head._y = top;
      body._y = top + head._height + 12;

      // Below the body, inside the panel's bottom padding.
      if(this.PopupPromptBar != undefined)
      {
         this.PopupPromptBar._y = body._y + body._height + 8;
      }

      // Centred on the panel, which is itself centred on screen.
      this.Popup._x = 0;
      this.Popup._y = 0;

      // Click-to-dismiss lives on a SEPARATE clip BEHIND the content, never on
      // this.Popup itself.
      //
      // A clip with an onRelease is a button in AS2, and a button SWALLOWS
      // mouse events for everything inside it. Putting the handler on the
      // popup therefore made the whole panel one big button: the text fields
      // never got the caret, and the Yes/No options could not be clicked --
      // every press was eaten before it reached them.
      //
      // A backdrop at depth 0 sits under the panel art and every control, so
      // it still catches clicks on empty space (and stops them falling through
      // to a day cell behind) while leaving the content clickable.
      var backdrop = this.Popup.createEmptyMovieClip("backdrop", 0);
      backdrop.beginFill(0x000000, 0);
      backdrop.moveTo(-MessageBox.POPUP_W / 2, -panelH / 2);
      backdrop.lineTo(MessageBox.POPUP_W / 2, -panelH / 2);
      backdrop.lineTo(MessageBox.POPUP_W / 2, panelH / 2);
      backdrop.lineTo(-MessageBox.POPUP_W / 2, panelH / 2);
      backdrop.endFill();

      backdrop.Owner = this;

      // focusEnabled stays false: a button would otherwise take focus off the
      // menu, killing every key.
      backdrop.focusEnabled = false;
      backdrop.tabEnabled = false;
      backdrop.onRelease = function()
      {
         // The editor has its own cancel; this only dismisses the day popup.
         if(this.Owner.Editing || this.Owner.Confirming)
         {
            return;
         }

         this.Owner.CloseDayPopup();
         gfx.io.GameDelegate.call("PlaySound", ["UIMenuCancel"]);
      };
      backdrop.useHandCursor = false;

      gfx.io.GameDelegate.call("PlaySound", ["UIMenuOK"]);
   }

   function CloseDayPopup()
   {
      // The editor is a child of the popup, so tearing the popup down without
      // ending the edit would destroy the field while the game still believed
      // text input was active -- and AllowTextInput would never be turned back
      // off. See EndEdit: that is the failure that leaves the player unable to
      // move after closing the menu.
      if(this.Editing)
      {
         this.EndEdit(false);
      }

      if(this.Popup != undefined)
      {
         this.Popup.removeMovieClip();
         this.Popup = undefined;
      }
      this.PopupDay = undefined;
   }

   // ---- the note editor -------------------------------------------------
   //
   // Two input fields (name, description) over the day popup, with the game's
   // keyboard handed to Flash while they are open.
   //
   // THE INPUT CONTRACT, which is the whole difficulty of this feature:
   //
   //   * The game must be told to stop treating keystrokes as game input, or
   //     the player types "w" and walks forward instead. This goes through the
   //     plugin (BeginTextInput / EndTextInput -> RE::ControlMap
   //     ::AllowTextInput), NOT through fscommand("AllowTextInput", ...):
   //     Skyrim never routes that fscommand to its control map, so the movie
   //     asking for it does nothing at all and every key stays with the game.
   //
   //   * Selection.setFocus(field) puts the caret in the field. Focus must be
   //     on the FIELD, not the menu, or the keys arrive nowhere.
   //
   //   * handleInput must return true for everything while editing (so no key
   //     reaches the grid behind) and must still DELEGATE down pathToFocus, or
   //     the field never sees the characters and typing is silently dead.
   //
   //   * AllowTextInput MUST be turned back off on every exit path. Leaving it
   //     on outlives the menu: the player closes the calendar and cannot move.
   //     Every exit therefore goes through EndEdit, and CloseDayPopup calls it
   //     defensively above.
   function BeginEdit(aDay)
   {
      if(this.Editing || this.Popup == undefined)
      {
         return;
      }

      this.Editing = true;
      this.EditDay = aDay;
      this.EditField = 0;

      // Whatever the day already has, so editing is editing rather than
      // always starting blank.
      var existing = this.FindNote(aDay);
      var startName = existing != undefined ? existing.name : "";
      var startDesc = existing != undefined ? existing.description : "";

      var innerW = MessageBox.POPUP_W - MessageBox.POPUP_PAD * 2;
      var left = -innerW / 2;

      this.EditLayer = this.Popup.createEmptyMovieClip("edit", 50);

      // An opaque backing, so the popup's own text does not show through the
      // editor and make it unreadable. Drawn BEFORE the border is attached, so
      // the panel art sits on top of the fill rather than behind it.
      this.EditLayer.beginFill(0x000000, 90);
      this.EditLayer.moveTo(-MessageBox.EDIT_W / 2, -MessageBox.EDIT_H / 2);
      this.EditLayer.lineTo(MessageBox.EDIT_W / 2, -MessageBox.EDIT_H / 2);
      this.EditLayer.lineTo(MessageBox.EDIT_W / 2, MessageBox.EDIT_H / 2);
      this.EditLayer.lineTo(-MessageBox.EDIT_W / 2, MessageBox.EDIT_H / 2);
      this.EditLayer.endFill();

      // The same vanilla border the day popup and the confirmation use, so all
      // three windows in this menu match.
      //
      // Sized only -- CalendarPanel's registration point is its centre, so
      // setting _x/_y as well would push it half a panel off the window.
      var editPanel = this.EditLayer.attachMovie("CalendarPanel", "epanel", 0);
      editPanel._width = MessageBox.FitToStage(MessageBox.EDIT_W, false);
      editPanel._height = MessageBox.FitToStage(MessageBox.EDIT_H, true);

      // 30px, not 24: at FONT_SIZE (22pt) a 24px field clips the descenders
      // and the bottom of the glyphs. Text field height has to clear the point
      // size with room to spare, not merely match it.
      var head = this.EditLayer.createTextField("ehead", 1, left, -100, innerW, 30);
      head.selectable = false;
      head.html = true;
      head.noTranslate = true;
      head.htmlText = this.Markup(this.Label("noteEdit", "Note"),
                                  MessageBox.FONT_SIZE, true);

      this.EditNameLabel = this.MakeEditLabel("lname", 2, left, -68,
                                              this.Label("noteName", "Name"));
      this.EditName = this.MakeEditField("fname", 3, left, -44, innerW, 26, startName);

      this.EditDescLabel = this.MakeEditLabel("ldesc", 4, left, -8,
                                              this.Label("noteDesc", "Description"));
      this.EditDesc = this.MakeEditField("fdesc", 5, left, 16, innerW, 52, startDesc);
      this.EditDesc.multiline = true;
      this.EditDesc.wordWrap = true;

      // A prompt bar, not a line of text: icon + caption per command, clickable
      // exactly like the month prompts at the top of the menu.
      this.Confirming = false;
      this.BuildEditPrompts(76);

      // Hand the keyboard over, then focus. In that order: focusing a field
      // the game is still filtering for would drop the first keystrokes.
      //
      // Through C++, NOT fscommand("AllowTextInput", ...). Skyrim does not
      // route that fscommand to its control map, so the movie's request was
      // silently ignored: the field focused, the caret blinked, and every
      // keystroke was still eaten by the game as movement. The plugin calls
      // RE::ControlMap::AllowTextInput instead, which is the real switch.
      // skse.AllowTextInput(true), called straight from ActionScript.
      //
      // This is what SkyUI's own search box does (skyui.components
      // .SearchWidget.startInput) -- SKSE injects AllowTextInput into every
      // Scaleform movie, so no round trip to the plugin is needed. Going
      // through C++ worked for the refcount but left the movie's own view of
      // text mode unset, which is part of why characters never landed.
      //
      // The plugin is still told, because it has to suppress its own hotkey
      // and the menu-control group while a field is live.
      gfx.io.GameDelegate.call("BeginTextInput", []);
      if(skse != undefined)
      {
         skse.AllowTextInput(true);
      }

      // Remember what had focus, so it can be restored exactly the way
      // SearchWidget.endInput does.
      this.PreviousFocus = gfx.managers.FocusHandler.instance.getFocus(0);

      // Before focusing: a cell that can still take focus will steal it back
      // the moment the first navigation-ish key arrives.
      this.SetCellsFocusable(false);

      this.FocusEditField(0);

      gfx.io.GameDelegate.call("PlaySound", ["UIMenuFocus"]);
   }

   // Writes to the plugin's log. The movie has nowhere else to report, and
   // guessing at ActionScript behaviour from in-game symptoms has already cost
   // more than one build.
   function Log(asText)
   {
      gfx.io.GameDelegate.call("Log", [String(asText)]);
   }


   // Remove the note on the day being edited, then close the editor.
   //
   // The delete goes through C++ (DeleteNote), which removes it from the store
   // and schedules the month re-push. EndEdit(false) is used deliberately --
   // saving here would immediately write the fields back and undo the delete.
   function DeleteNote()
   {
      var day = this.EditDay;

      this.EndEdit(false);

      if(day != undefined)
      {
         gfx.io.GameDelegate.call(
            "DeleteNote", [this.Data.year, this.Data.month, day.day]);
         gfx.io.GameDelegate.call("PlaySound", ["UIMenuCancel"]);
      }
   }

   // ---- the delete confirmation -----------------------------------------
   //
   // A small Yes / No panel over the editor, rather than a second press of the
   // delete key. Deleting is the one destructive thing this menu does, and a
   // modal question is both clearer than a changing hint line and impossible
   // to trigger by accident.
   //
   // It is drawn INSIDE the editor layer, so it is torn down automatically if
   // the edit ends for any reason -- there is no way to leave the confirm
   // panel orphaned on screen.
   //
   // Text input stays on while it is open: the fields keep their contents so
   // that answering No returns the player to exactly what they were typing.
   // Clamp a window dimension to what the stage can actually show.
   //
   // These windows are a fixed size and comfortably fit the authored 1280x720
   // stage, so this changes nothing today. It is here so that editing EDIT_H
   // or CONFIRM_W later cannot quietly reintroduce the bug the grid already
   // had: a panel bigger than the stage is clipped equally top and bottom,
   // which reads as "the mod is broken on my resolution" rather than as a
   // number being too large.
   //
   // Note this is NOT about the player's monitor. Skyrim scales the whole
   // movie to the screen, so the budget is the stage's 1280x720 at every
   // resolution -- a bigger monitor does not grant more room.
   static function FitToStage(aiSize, abVertical)
   {
      var avail = (abVertical ? MessageBox.STAGE_H : MessageBox.STAGE_W)
                - MessageBox.SCREEN_PAD * 2;
      return aiSize > avail ? avail : aiSize;
   }

   function OpenDeleteConfirm()
   {
      if(this.Confirming || this.EditLayer == undefined)
      {
         return;
      }

      this.Confirming = true;

      var w = MessageBox.FitToStage(MessageBox.CONFIRM_W, false);
      var h = MessageBox.FitToStage(MessageBox.CONFIRM_H, true);
      var innerW = w - MessageBox.POPUP_PAD * 2;
      var left = -innerW / 2;

      // Above every editor field.
      this.ConfirmLayer = this.EditLayer.createEmptyMovieClip("confirm", 90);

      // The vanilla border art, the same symbol the day popup uses, rather
      // than a drawn rectangle. It carries a DefineScalingGrid (9-slice), so
      // setting _width/_height stretches it without smearing the corners --
      // and the window then matches every other panel in the menu instead of
      // looking like something this mod drew itself.
      // _width and _height ONLY -- do not set _x/_y.
      //
      // CalendarPanel's registration point is already its centre, which is why
      // the day popup positions it by size alone. Setting _x = -w/2 as well
      // shifted the border half a panel off the window it was supposed to
      // frame.
      var panel = this.ConfirmLayer.attachMovie("CalendarPanel", "cpanel", 1);
      panel._width = w;
      panel._height = h;

      var q = this.ConfirmLayer.createTextField("cq", 2, left, -h / 2 + 24, innerW, 32);
      q.selectable = false;
      q.html = true;
      q.noTranslate = true;
      q.wordWrap = true;
      q.multiline = true;
      q.htmlText = this.Markup(
         this.Label("noteDeleteAsk", "Delete this note?"),
         MessageBox.FONT_SIZE, true);

      // Enter Yes / Tab No, as key prompts -- exactly how the vanilla wait
      // menu asks the same question.
      //
      // There is NO selection here and no cursor to move: each answer is bound
      // to its own key and the icon says which. That is the whole pattern, and
      // it is why this uses the prompt bar rather than a pair of buttons --
      // buttons would imply a highlight to move around, which vanilla does not
      // have.
      //
      // AddEditPrompt is reused as-is, so these get the same icon+caption
      // construction, the same hover dimming and the same click handling as
      // every other prompt in the menu.
      this.ConfirmPrompts = new Array();
      var cbar = this.ConfirmLayer.createEmptyMovieClip("cbar", 3);
      this.ConfirmPromptBar = cbar;

      this.AddEditPrompt(cbar, this.ConfirmPrompts, MessageBox.SCAN_ENTER,
                         this.Label("yes", "Yes"), "OnConfirmYes");
      this.AddEditPrompt(cbar, this.ConfirmPrompts, MessageBox.SCAN_TAB,
                         this.Label("no", "No"), "OnConfirmNo");

      // Laid out from the measured widths, the way LayoutPrompts does it.
      var ctotal = 0;
      var ci = 0;
      while(ci < this.ConfirmPrompts.length)
      {
         ctotal = ctotal + this.ConfirmPrompts[ci]._width + MessageBox.CONFIRM_GAP;
         ci = ci + 1;
      }
      ctotal = ctotal - MessageBox.CONFIRM_GAP;

      var cx = -ctotal / 2;
      ci = 0;
      while(ci < this.ConfirmPrompts.length)
      {
         this.ConfirmPrompts[ci]._x = cx;
         cx = cx + this.ConfirmPrompts[ci]._width + MessageBox.CONFIRM_GAP;
         ci = ci + 1;
      }

      cbar._y = h / 2 - 46;

      gfx.io.GameDelegate.call("PlaySound", ["UIMenuFocus"]);
   }

   function OnConfirmYes()
   {
      this.CloseDeleteConfirm();
      this.DeleteNote();
   }

   function OnConfirmNo()
   {
      this.CloseDeleteConfirm();
      gfx.io.GameDelegate.call("PlaySound", ["UIMenuCancel"]);
   }

   function CloseDeleteConfirm()
   {
      if(!this.Confirming)
      {
         return;
      }

      this.Confirming = false;

      if(this.ConfirmLayer != undefined)
      {
         this.ConfirmLayer.removeMovieClip();
         this.ConfirmLayer = undefined;
      }
      this.ConfirmPromptBar = undefined;
      this.ConfirmPrompts = undefined;

      // Focus back to the field that had it, so answering No resumes typing
      // where the player left off.
      this.FocusEditField(this.EditField);
   }

   // The editor's prompt bar: save, switch field, delete, cancel.
   //
   // Built the same way the month prompts are -- ButtonArt icon plus caption,
   // clickable, laid out from MEASURED widths -- so the two bars look and
   // behave alike and a player learns one thing, not two.
   //
   // Icons come from the live bindings, so a rebind in the INI moves the key
   // and its picture together.
   function BuildEditPrompts(aiY)
   {
      this.EditPrompts = new Array();

      var bar = this.EditLayer.createEmptyMovieClip("ebar", 7);
      this.EditPromptBar = bar;

      this.AddEditPrompt(bar, this.EditPrompts, this.NoteSaveScan,
                         this.Label("noteSave", "Save"), "OnPromptSave");
      this.AddEditPrompt(bar, this.EditPrompts, this.NoteSwitchScan,
                         this.Label("noteSwitch", "Switch field"), "OnPromptSwitch");
      this.AddEditPrompt(bar, this.EditPrompts, this.NoteDeleteScan,
                         this.Label("noteDelete", "Delete"), "OnPromptDelete",
                         this.NoteDeleteCtrl);
      this.AddEditPrompt(bar, this.EditPrompts, this.NoteCancelScan,
                         this.Label("noteCancel", "Cancel"), "OnPromptCancel");

      // Centred as a row, from the widths the icons actually came out at.
      var total = 0;
      var i = 0;
      while(i < this.EditPrompts.length)
      {
         total = total + this.EditPrompts[i]._width + MessageBox.EDIT_PROMPT_GAP;
         i = i + 1;
      }
      total = total - MessageBox.EDIT_PROMPT_GAP;

      var x = -total / 2;
      i = 0;
      while(i < this.EditPrompts.length)
      {
         this.EditPrompts[i]._x = x;
         x = x + this.EditPrompts[i]._width + MessageBox.EDIT_PROMPT_GAP;
         i = i + 1;
      }

      bar._y = aiY;
   }

   // One editor prompt. abCtrl prefixes the caption with CTRL+ for a command
   // that needs the modifier, so the icon does not have to lie about it.
   function AddEditPrompt(aBar, aList, aiScanCode, asLabel, asHandler, abCtrl)
   {
      var i = aList.length;
      var holder = aBar.createEmptyMovieClip("ep" + i, i);

      var icon = holder.attachMovie("ButtonArt", "icon", 1);
      icon.gotoAndStop(aiScanCode);

      var caption = abCtrl ? "CTRL+" + asLabel : asLabel;

      var label = holder.createTextField(
         "cap", 2, icon._width + MessageBox.PROMPT_ICON_GAP, 0, 200, 26);
      label.selectable = false;
      label.html = true;
      label.noTranslate = true;
      label.autoSize = "left";
      label.htmlText = this.Markup(caption, MessageBox.FONT_SIZE_HINT, false);

      label._y = (icon._height - label._height) / 2;

      holder.Owner = this;
      holder.Handler = asHandler;

      // MUST refuse focus.
      //
      // A clip with an onRelease is a button in AS2, and a button takes focus
      // when clicked -- which would pull focus OUT of the text field and stop
      // the player typing. The month prompts refuse focus for the same reason
      // (there it killed the keyboard entirely); here it would also silently
      // end text entry.
      holder.focusEnabled = false;
      holder.tabEnabled = false;

      // Width captured before the fill is drawn, since the fill becomes part
      // of the clip and would otherwise feed back into the measurement.
      var hitW = holder._width;

      holder.beginFill(0x000000, 0);
      holder.moveTo(0, 0);
      holder.lineTo(hitW, 0);
      holder.lineTo(hitW, MessageBox.PROMPT_HIT_H);
      holder.lineTo(0, MessageBox.PROMPT_HIT_H);
      holder.endFill();

      // The same hover treatment as the month prompts at the top of the menu:
      // dim on roll-over, restore on roll-out and on release. Kept identical
      // deliberately, so every prompt in this menu reacts the same way.
      holder.onRollOver = function()
      {
         this._alpha = 60;
      };
      holder.onRollOut = function()
      {
         this._alpha = 100;
      };
      holder.onRelease = function()
      {
         this._alpha = 100;
         this.Owner[this.Handler]();
      };
      holder.useHandCursor = true;

      aList.push(holder);
      return holder;
   }

   function OnPromptAddNote() { this.BeginEdit(this.PopupDay); }

   function OnPromptSave() { this.EndEdit(true); }
   function OnPromptCancel() { this.EndEdit(false); }
   function OnPromptDelete() { this.OpenDeleteConfirm(); }

   function OnPromptSwitch()
   {
      this.FocusEditField(this.EditField == 0 ? 1 : 0);
   }

   // A printable name for a scan code, for the hint line.
   //
   // Only the keys the editor can plausibly be bound to are named; anything
   // else falls back to the number, which is still enough for a player who
   // rebound it to recognise what they set.
   static function ScanName(aiScan)
   {
      if(MessageBox.ScanNames == undefined)
      {
         MessageBox.ScanNames = new Object();
         MessageBox.ScanNames[1] = "ESC";
         MessageBox.ScanNames[14] = "BACKSPACE";
         MessageBox.ScanNames[15] = "TAB";
         MessageBox.ScanNames[28] = "ENTER";
         MessageBox.ScanNames[57] = "SPACE";
         MessageBox.ScanNames[59] = "F1";
         MessageBox.ScanNames[60] = "F2";
         MessageBox.ScanNames[61] = "F3";
         MessageBox.ScanNames[62] = "F4";
         MessageBox.ScanNames[211] = "DELETE";

         // Letters, so a rebind to any of them reads correctly.
         var letters = "QWERTYUIOP";
         var i = 0;
         while(i < letters.length)
         {
            MessageBox.ScanNames[16 + i] = letters.charAt(i);
            i = i + 1;
         }
         letters = "ASDFGHJKL";
         i = 0;
         while(i < letters.length)
         {
            MessageBox.ScanNames[30 + i] = letters.charAt(i);
            i = i + 1;
         }
         letters = "ZXCVBNM";
         i = 0;
         while(i < letters.length)
         {
            MessageBox.ScanNames[44 + i] = letters.charAt(i);
            i = i + 1;
         }
      }

      var name = MessageBox.ScanNames[aiScan];
      return name != undefined ? name : String(aiScan);
   }

   function MakeEditLabel(asName, aiDepth, aiX, aiY, asText)
   {
      var f = this.EditLayer.createTextField(asName, aiDepth, aiX, aiY, 200, 20);
      f.selectable = false;
      f.html = true;
      f.noTranslate = true;
      f.htmlText = this.Markup(asText, MessageBox.FONT_SIZE_HINT, false);
      return f;
   }

   // An editable field.
   //
   // The font is set with a TextFormat rather than inline markup, because an
   // input field's text is PLAIN: what the player types replaces the contents,
   // so an HTML font tag would either be typed over or shown literally. The
   // embedded font is what makes setTextFormat enough here -- see FONT.
   function MakeEditField(asName, aiDepth, aiX, aiY, aiW, aiH, asValue)
   {
      var f = this.EditLayer.createTextField(asName, aiDepth, aiX, aiY, aiW, aiH);
      f.type = "input";
      f.border = true;
      f.borderColor = MessageBox.FRAME_LINE_COLOR;
      f.background = true;
      f.backgroundColor = 0x101010;
      f.selectable = true;
      f.html = false;
      f.noTranslate = true;
      f.maxChars = MessageBox.NOTE_MAX_CHARS;

      // An input TextField must be able to hold focus for a click to place the
      // caret. tabEnabled is off so Tab stays OURS -- the editor moves between
      // the two fields itself, and Flash's own tab order would fight it.
      f.focusEnabled = true;
      f.tabEnabled = false;

      var fmt = new TextFormat();
      fmt.font = MessageBox.FONT;
      fmt.size = MessageBox.FONT_SIZE_SMALL;
      fmt.color = 0xFFFFFF;
      f.setNewTextFormat(fmt);

      f.text = asValue;
      f.setTextFormat(fmt);

      // Clicking a field must also tell the editor which field is live.
      //
      // Flash moves the caret on its own, but EditField would go stale -- Tab
      // would then jump from the wrong field, and the border highlight would
      // point at the other box. onSetFocus fires for the mouse and for
      // Selection.setFocus alike, so the two paths cannot diverge.
      f.Owner = this;
      f.FieldIndex = asName == "fdesc" ? 1 : 0;
      f.onSetFocus = function()
      {
         this.Owner.OnEditFieldFocused(this.FieldIndex);
      };

      return f;
   }

   // A field took focus, from a click or from FocusEditField.
   //
   // Only the bookkeeping and the highlight -- deliberately NOT setFocus,
   // which would recurse straight back into this handler.
   function OnEditFieldFocused(aiWhich)
   {
      this.EditField = aiWhich;
      this.RefreshFieldHighlight();
   }

   // The border colour that shows which field has the keyboard.
   function RefreshFieldHighlight()
   {
      if(this.EditName == undefined || this.EditDesc == undefined)
      {
         return;
      }

      this.EditName.borderColor = this.EditField == 0 ? MessageBox.SELECTION_COLOR
                                                      : MessageBox.FRAME_LINE_COLOR;
      this.EditDesc.borderColor = this.EditField == 1 ? MessageBox.SELECTION_COLOR
                                                      : MessageBox.FRAME_LINE_COLOR;
   }

   // Stop the day cells taking focus away from the editor.
   //
   // The cells are gfx.controls.Button instances, and a Button grabs focus on
   // navigation input. Now that handleInput correctly returns false while
   // editing (so characters can reach the field), those keys also reach the
   // buttons -- and the log showed focus jumping from edit.fname to
   // Cells.day12 after a few keystrokes, at which point every further
   // character went to a button instead of the text field.
   //
   // disableFocus is gfx.controls.Button's own opt-out, so this uses the
   // component's supported mechanism rather than fighting it.
   function SetCellsFocusable(abFocusable)
   {
      var i = 0;
      while(i < this.Cells.length)
      {
         if(this.Cells[i] != undefined)
         {
            this.Cells[i].disableFocus = !abFocusable;
            this.Cells[i].focusEnabled = abFocusable;
            this.Cells[i].tabEnabled = abFocusable;
         }
         i = i + 1;
      }
   }

   function FocusEditField(aiWhich)
   {
      this.EditField = aiWhich;

      var field = aiWhich == 0 ? this.EditName : this.EditDesc;

      // Selection.setFocus ONLY.
      //
      // Do NOT also call gfx.managers.FocusHandler.instance.setFocus(field, 0).
      // That writes currentFocusLookup, which is what getPathToFocus walks, and
      // pointing it at a bare TextField -- which has no handleInput -- breaks
      // dispatch to this menu entirely. SkyUI's search widget, the reference
      // implementation for a Scaleform text field, never calls it either.
      // Adding it is what put "focus=none" in the log.
      Selection.setFocus(field);

      // Caret to the end, so typing continues an existing note rather than
      // overwriting from the start.
      Selection.setSelection(field.text.length, field.text.length);

      // Show which field has the keyboard. The border is the only cue -- an
      // input field's own caret is easy to miss at this size.
      this.RefreshFieldHighlight();
   }

   // The single exit. abSave decides whether the text is kept.
   //
   // Everything that stops editing comes through here, because this is where
   // AllowTextInput is turned back off -- and missing that once leaves the
   // player unable to move long after the menu is gone.
   function EndEdit(abSave)
   {
      if(!this.Editing)
      {
         return;
      }

      var name = this.EditName.text;
      var desc = this.EditDesc.text;
      var day = this.EditDay;

      // Cleared BEFORE the round trip to C++. SaveNote re-pushes the month,
      // which rebuilds the grid and can close this popup: with Editing still
      // true, CloseDayPopup would re-enter EndEdit.
      this.Editing = false;
      this.EditDay = undefined;

      // The confirm panel is a child of EditLayer and dies with it, but the
      // FLAG is not -- and a stale Confirming would swallow every key in
      // handleInput with no panel on screen to explain why.
      this.Confirming = false;
      this.ConfirmLayer = undefined;

      gfx.io.GameDelegate.call("EndTextInput", []);
      if(skse != undefined)
      {
         skse.AllowTextInput(false);
      }

      if(this.EditLayer != undefined)
      {
         this.EditLayer.removeMovieClip();
         this.EditLayer = undefined;
      }
      this.EditName = undefined;
      this.EditDesc = undefined;

      // The grid takes focus again now the editor is gone.
      this.SetCellsFocusable(true);

      // Focus back inside the menu, never null -- an empty focus path stops
      // handleInput being dispatched at all and kills every key.
      //
      // Restored the way SearchWidget.endInput does it: focusEnabled is forced
      // on for the setFocus call and then put back, because a component that
      // is not focusable silently refuses focus and would leave the path
      // empty.
      var prev = this.PreviousFocus;
      this.PreviousFocus = undefined;

      // `prev` is usually a day cell, and saving a note re-pushes the month --
      // which destroys and rebuilds every cell. Focusing a clip that is about
      // to be removed leaves the focus path dangling, so its continued
      // existence is checked rather than assumed. (_parent goes undefined on a
      // removed MovieClip, which is the cheap test for it.)
      if(prev != undefined && prev._parent != undefined)
      {
         var wasEnabled = prev.focusEnabled;
         prev.focusEnabled = true;
         Selection.setFocus(prev, 0);
         prev.focusEnabled = wasEnabled;
      }
      else
      {
         Selection.setFocus(this);
      }

      if(abSave && day != undefined)
      {
         gfx.io.GameDelegate.call(
            "SaveNote", [this.Data.year, this.Data.month, day.day, name, desc]);
         gfx.io.GameDelegate.call("PlaySound", ["UIMenuOK"]);
      }
      else
      {
         gfx.io.GameDelegate.call("PlaySound", ["UIMenuCancel"]);
      }
   }

   // The player's own entry on a day, or undefined. Keyed on isNote, which
   // C++ sets -- the kind string alone is not enough, since authored JSON may
   // legitimately use "note" too.
   function FindNote(aDay)
   {
      if(aDay == undefined || aDay.events == undefined)
      {
         return undefined;
      }
      var i = 0;
      while(i < aDay.events.length)
      {
         if(aDay.events[i].isNote)
         {
            return aDay.events[i];
         }
         i = i + 1;
      }
      return undefined;
   }

      // ---- layout --------------------------------------------------------
   //
   // Background_mc is the vanilla panel and carries a DefineScalingGrid
   // (9-slice), so setting _width/_height scales the border art correctly,
   // corners and all. The shape is 432x155px naturally with ~30px slice
   // margins, so it takes this much stretch without the border smearing.
   //
   // Everything is laid out around (0,0) because MessageMenu is placed at
   // (640,360) on a 1280x720 stage -- the origin is already screen centre.
   // Choose the tallest CELL_H whose panel still fits on screen.
   //
   // Solved rather than guessed, so that changing HEADER_H, FOOTER_H, MARGIN,
   // ROWS or the preferred height can never push the menu off-screen again --
   // the fixed furniture is subtracted from the budget and the rows divide
   // what is left.
   //
   // Uses Stage.height when it is available and sane, falling back to the
   // authored 720. Skyrim scales the movie rather than resizing the stage, so
   // in practice this is 720 everywhere; the read is here so an unusual host
   // (or a future menu that is not scaled) cannot silently clip.
   function FitCellHeight()
   {
      var avail = MessageBox.STAGE_H;
      if(Stage.height > 100)
      {
         avail = Stage.height;
      }
      avail = avail - MessageBox.SCREEN_PAD * 2;

      var fixed = MessageBox.HEADER_H + MessageBox.FOOTER_H
                + MessageBox.MARGIN * 2
                + (MessageBox.ROWS - 1) * MessageBox.CELL_GAP;

      var perRow = Math.floor((avail - fixed) / MessageBox.ROWS);

      if(perRow > MessageBox.CELL_H_PREFERRED)
      {
         perRow = MessageBox.CELL_H_PREFERRED;
      }

      // A floor, deliberately. If the furniture ever grows so large that even
      // the minimum does not fit, letting the cells collapse to nothing would
      // be worse than overflowing -- and an unreadable grid hides the cause.
      if(perRow < MessageBox.CELL_H_MIN)
      {
         perRow = MessageBox.CELL_H_MIN;
      }

      MessageBox.CELL_H = perRow;
   }

   function ResetDimensions()
   {
      // Before anything is measured: every dimension below depends on it.
      this.FitCellHeight();

      var gridW = MessageBox.COLS * MessageBox.CELL_W
                + (MessageBox.COLS - 1) * MessageBox.CELL_GAP;
      var gridH = MessageBox.ROWS * MessageBox.CELL_H
                + (MessageBox.ROWS - 1) * MessageBox.CELL_GAP;

      var w = gridW + MessageBox.MARGIN * 2;
      var h = gridH + MessageBox.HEADER_H + MessageBox.FOOTER_H
            + MessageBox.MARGIN * 2;

      this.Background_mc._width = w;
      this.Background_mc._height = h;

      var left = -gridW / 2;
      var top  = -h / 2 + MessageBox.MARGIN;

      // The heading no longer autoSizes (the stage field is multiline with
      // wordWrap), so it is positioned and sized explicitly and centred by
      // the <p align='center'> in SetCalendarData.
      this.HeadingText._x = left;
      this.HeadingText._y = top - 6;
      this.HeadingText._width = gridW;
      this.HeadingText._height = 30;

      this.TodayText._x = left;
      this.TodayText._y = top + 26;
      this.TodayText._width = gridW;

      // The prompt bar, where the < / TODAY / > buttons used to sit. It is
      // centred on the panel's midline, so only _y is set -- AddPrompt and
      // LayoutPrompts handle the horizontal placement.
      if(this.PromptBar != undefined)
      {
         this.PromptBar._x = 0;
         this.PromptBar._y = top + 62;
      }

      // Weekday labels sit directly above the first row of cells.
      this.HeaderContainer._x = 0;
      this.HeaderContainer._y = top + MessageBox.HEADER_H - 24;

      // The container sits at the grid's top-left. A cell's origin is its
      // centre, which BuildGrid already compensates for on both axes.
      this.CellContainer._x = 0;
      this.CellContainer._y = top + MessageBox.HEADER_H;

      // The frames are placed with the same cell centres, so the container
      // must sit exactly where the cell container does or every box would be
      // offset from the button it belongs to.
      this.FrameContainer._x = this.CellContainer._x;
      this.FrameContainer._y = this.CellContainer._y;

      var gridBottom = top + MessageBox.HEADER_H + gridH;

      // The vanilla divider, reused as the rule between grid and detail.
      if(this.Divider != undefined)
      {
         this.Divider._width = gridW;
         this.Divider._y = gridBottom + 14;
      }

      this.DetailText._x = left;
      this.DetailText._y = gridBottom + 24;
      this.DetailText._width = gridW;
      this.DetailText._height = MessageBox.DETAIL_LINES * MessageBox.DETAIL_LINE_H;
   }

   function SetPlatform(aiPlatform, abPS3Switch)
   {
      this.iPlatform = aiPlatform;

      // On a gamepad the cells take focus; with mouse and keyboard the
      // vanilla menus disable it so the pointer drives instead.
      var i = 0;
      while(i < this.Cells.length)
      {
         this.Cells[i].disableFocus = aiPlatform == 0 ? false : false;
         i = i + 1;
      }
   }
}
