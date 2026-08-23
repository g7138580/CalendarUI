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
   static var CELL_H = 55;
   static var CELL_GAP = 4;
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
   static var POPUP_W = 520;
   static var POPUP_PAD = 30;
   static var POPUP_MIN_H = 110;

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

      if(Shared.GlobalFunc.IsKeyPressed(details))
      {
         // While the popup is open it owns the keyboard: anything that would
         // page the month behind it is swallowed, and only close gets through.
         // Returning true either way stops the key reaching the grid.
         if(this.Popup != undefined)
         {
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
      }

      this.SelectedIndex = aiIndex;

      var cell = this.Cells[aiIndex];
      if(cell != undefined)
      {
         cell.focused = 1;
         Selection.setFocus(cell);
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
      this.Cells.length = 0;

      // Fixed depths, not getNextHighestDepth(). BuildGrid runs on every month
      // change, so allocating a fresh depth each time would climb without
      // bound as the player pages -- and would eventually overtake the nav
      // buttons, which are allocated once in the constructor.
      this.HeaderContainer = this.createEmptyMovieClip("Headers", MessageBox.DEPTH_HEADERS);
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
      if(aDay == undefined || aDay.events.length == 0)
      {
         return;
      }

      this.CloseDayPopup();

      // A child of the menu, so the focus path still reaches our handleInput.
      // Attached to _root instead, every key would stop working while it was
      // open.
      this.Popup = this.createEmptyMovieClip("DayPopup", MessageBox.DEPTH_POPUP);

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
      body.htmlText = this.MarkupBlock(out);

      // Height comes from the text, measured after it is set. autoSize keeps
      // _height honest, so nothing here has to guess at a line count.
      var contentH = head._height + 12 + body._height;
      var panelH = contentH + MessageBox.POPUP_PAD * 2;
      if(panelH < MessageBox.POPUP_MIN_H)
      {
         panelH = MessageBox.POPUP_MIN_H;
      }

      panel._width = MessageBox.POPUP_W;
      panel._height = panelH;

      var top = -panelH / 2 + MessageBox.POPUP_PAD;
      head._y = top;
      body._y = top + head._height + 12;

      // Centred on the panel, which is itself centred on screen.
      this.Popup._x = 0;
      this.Popup._y = 0;

      // Click the popup to dismiss it. The fill is transparent but covers the
      // whole panel, so the click cannot fall through to a day cell behind.
      // focusEnabled stays false: a clip with an onRelease is a button in AS2
      // and would take focus off the menu, killing every key.
      this.Popup.beginFill(0x000000, 0);
      this.Popup.moveTo(-MessageBox.POPUP_W / 2, -panelH / 2);
      this.Popup.lineTo(MessageBox.POPUP_W / 2, -panelH / 2);
      this.Popup.lineTo(MessageBox.POPUP_W / 2, panelH / 2);
      this.Popup.lineTo(-MessageBox.POPUP_W / 2, panelH / 2);
      this.Popup.endFill();

      this.Popup.Owner = this;
      this.Popup.focusEnabled = false;
      this.Popup.tabEnabled = false;
      this.Popup.onRelease = function()
      {
         this.Owner.CloseDayPopup();
         gfx.io.GameDelegate.call("PlaySound", ["UIMenuCancel"]);
      };
      this.Popup.useHandCursor = false;

      gfx.io.GameDelegate.call("PlaySound", ["UIMenuOK"]);
   }

   function CloseDayPopup()
   {
      if(this.Popup != undefined)
      {
         this.Popup.removeMovieClip();
         this.Popup = undefined;
      }
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
   function ResetDimensions()
   {
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
