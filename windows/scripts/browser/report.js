// What the browser test reads back: the field's text in the window title (a counter in it shows
// the page still runs), and every composition and input event in the console, which Chrome writes
// to chrome_debug.log with --enable-logging.
//   T:<beat>:[<text as JSON>]
(function () {
  let beat = 0;
  let text = "";
  window.reportText = (value) => { text = value; };
  const show = () => { document.title = "T:" + beat + ":[" + JSON.stringify(text) + "]"; };
  setInterval(() => { beat++; show(); }, 200);
  window.watchEvents = (element) => {
    for (const type of ["compositionstart", "compositionupdate", "compositionend"]) {
      element.addEventListener(type, (e) => console.log("araso-test " + type + " " + JSON.stringify(e.data)));
    }
    element.addEventListener("beforeinput", (e) =>
      console.log("araso-test beforeinput " + e.inputType + " " + JSON.stringify(e.data) + " composing " + e.isComposing));
    element.addEventListener("keydown", (e) => console.log("araso-test keydown " + e.key + " composing " + e.isComposing));
  };
  // The field takes the focus at once and whenever the window comes back.
  window.keepFocus = (element) => {
    const focus = () => element.focus();
    window.addEventListener("load", focus);
    window.addEventListener("focus", focus);
    setTimeout(focus, 300);
  };
  window.addEventListener("error", (e) => console.log("araso-test page error " + e.message));
})();
