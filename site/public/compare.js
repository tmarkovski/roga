// Lets the window under "Built for macOS" be dragged between light and dark.
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

// Once the window has been in view for a moment, the line swings a little to
// each side and back to the middle, to show that it moves. That happens once,
// and not at all for a reader who asks for less motion or takes hold of the
// line first.
const swing = { frame: 0, at: 50, over: false };

// Fractions of the swing's time, and where the line is by then. It eases in
// and out of each, so it seems to turn rather than bounce.
const swingStops = [[0, 50], [0.32, 57], [0.7, 44], [1, 50]];
const swingTime = 1600;

function swingAt(t) {
  const i = swingStops.findIndex(([end]) => end >= t);
  const [t0, from] = swingStops[i - 1];
  const [t1, to] = swingStops[i];
  return from + ((to - from) * (1 - Math.cos((Math.PI * (t - t0)) / (t1 - t0)))) / 2;
}

function startSwing() {
  if (swing.over) return;
  swing.over = true;
  let start;
  const step = (now) => {
    start ??= now;
    const t = (now - start) / swingTime;
    if (t >= 1) {
      swing.frame = 0;
      show(50);
      return;
    }
    swing.at = t > 0 ? swingAt(t) : 50;
    compare.style.setProperty("--split", `${swing.at}%`);
    swing.frame = requestAnimationFrame(step);
  };
  swing.frame = requestAnimationFrame(step);
}

// Leaves the line where the swing had it, for a drag or the arrow keys to
// carry on from.
function stopSwing() {
  swing.over = true;
  if (!swing.frame) return;
  cancelAnimationFrame(swing.frame);
  swing.frame = 0;
  show(swing.at);
}

let dragging = false;

compare.addEventListener("pointerdown", (event) => {
  stopSwing();
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
range.addEventListener("focus", stopSwing);

range.hidden = false;
compare.classList.add("ready");

// Waits for most of the window to be on screen, and for half a second more,
// so a reader scrolling past doesn't set it off.
if (!matchMedia("(prefers-reduced-motion: reduce)").matches && "IntersectionObserver" in window) {
  const images = [...compare.querySelectorAll("img")];
  let wait = 0;
  const watcher = new IntersectionObserver(
    ([entry]) => {
      clearTimeout(wait);
      if (swing.over) return watcher.disconnect();
      if (entry.intersectionRatio < 0.6) return;
      wait = setTimeout(async () => {
        watcher.disconnect();
        await Promise.all(images.map((image) => image.decode().catch(() => {})));
        startSwing();
      }, 500);
    },
    { threshold: 0.6 },
  );
  watcher.observe(compare);
}
