// Lets the window under "A real Mac app" be dragged between light and dark.
// Without this script the page shows it half and half, and nothing moves.

const compare = document.querySelector(".compare");
const range = compare.querySelector("input");

function show(percent) {
  const light = Math.min(100, Math.max(0, percent));
  compare.style.setProperty("--split", `${light}%`);
  range.value = Math.round(light);
  range.setAttribute("aria-valuetext", `${Math.round(light)}% light`);
}

function showPointer(event) {
  const box = compare.getBoundingClientRect();
  show(((event.clientX - box.left) / box.width) * 100);
}

let dragging = false;

compare.addEventListener("pointerdown", (event) => {
  if (event.button !== 0) return;
  dragging = true;
  compare.setPointerCapture(event.pointerId);
  // A finger landing here may be about to scroll the page, so only a mouse
  // moves the line before it has moved.
  if (event.pointerType === "mouse") showPointer(event);
});

compare.addEventListener("pointermove", (event) => {
  if (dragging) showPointer(event);
});

compare.addEventListener("pointercancel", () => {
  dragging = false;
});

// The arrow keys carry on from a drag. This waits for the release, because a
// press moves the focus away from anything focused before the browser's own
// handling of it finishes.
compare.addEventListener("pointerup", () => {
  if (dragging) range.focus({ preventScroll: true, focusVisible: false });
  dragging = false;
});

range.addEventListener("input", () => show(Number(range.value)));

range.hidden = false;
compare.classList.add("ready");
