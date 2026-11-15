// Turns the list of what the agents do into vertical tabs, with one picture
// showing at a time. Without this script every picture shows, one under the
// other, beside the list.
//
// The selected tab has the line the app draws around an agent's command
// (decision 68). Choosing a tab draws that line in: the light that runs around
// the app's Generate button under the pointer goes once around the tab from
// its top left, and the line follows behind it until it closes. The light's
// numbers are the app's, from AgentOutlineView.

const workflows = document.querySelector(".workflows");
const list = workflows.querySelector(".tabs");
const tabs = [...list.querySelectorAll(".tab")];
const panels = tabs.map((tab) => document.getElementById(tab.getAttribute("aria-controls")));
const reducesMotion = matchMedia("(prefers-reduced-motion: reduce)");

// The light is stacked from strokes that all end at its front, each starting a
// little further forward than the one under it, so that it brightens by small
// steps toward the front. Each adds the same step of brightness, and its color
// goes from the line's orange to the front's.
const bandCount = 16;
const bands = Array.from({ length: bandCount }, (_, index) => ({
  start: Math.pow(index / bandCount, 1 / 1.5),
  opacity: 1 / (bandCount - index),
  warmth: Math.min((index + 1) / bandCount / 0.75, 1),
}));
const pass = { duration: 1150, easing: "cubic-bezier(0.45, 0.05, 0.4, 0.95)" };

const svg = "http://www.w3.org/2000/svg";
const outline = document.createElementNS(svg, "svg");
outline.setAttribute("class", "outline");
outline.setAttribute("aria-hidden", "true");
const filter = document.createElementNS(svg, "filter");
filter.id = "tab-light-glow";
for (const [name, value] of [["x", "-50%"], ["y", "-50%"], ["width", "200%"], ["height", "200%"]]) {
  filter.setAttribute(name, value);
}
const shadow = document.createElementNS(svg, "feDropShadow");
shadow.setAttribute("dx", "0");
shadow.setAttribute("dy", "0");
shadow.setAttribute("stdDeviation", "1.75");
shadow.style.floodColor = "var(--agent-glow)";
filter.append(shadow);
const still = document.createElementNS(svg, "rect");
still.setAttribute("class", "still");
const light = document.createElementNS(svg, "g");
light.setAttribute("class", "light");
const strokes = bands.map((band) => {
  const stroke = document.createElementNS(svg, "rect");
  stroke.style.stroke = `color-mix(in srgb, var(--agent-light) ${band.warmth * 100}%, var(--agent-orange))`;
  stroke.style.strokeOpacity = band.opacity;
  return stroke;
});
// Only the front glows.
strokes[bandCount - 1].setAttribute("filter", "url(#tab-light-glow)");
light.append(...strokes);
outline.append(filter, still, light);

let selected = 0;

// Draws the line on the selected tab's border, and says how long it is.
function fit() {
  const tab = tabs[selected];
  const width = tab.offsetWidth;
  const height = tab.offsetHeight;
  const radius = Math.max((parseFloat(getComputedStyle(tab).borderTopLeftRadius) || 0) - 0.5, 0);
  outline.setAttribute("viewBox", `0 0 ${width} ${height}`);
  // Inside the edge, so that a one-pixel line is on whole pixels.
  for (const rect of [still, ...strokes]) {
    rect.setAttribute("x", "0.5");
    rect.setAttribute("y", "0.5");
    rect.setAttribute("width", String(Math.max(width - 1, 0)));
    rect.setAttribute("height", String(Math.max(height - 1, 0)));
    rect.setAttribute("rx", String(radius));
  }
  const w = width - 1;
  const h = height - 1;
  return 2 * (w + h) - 8 * radius + 2 * Math.PI * radius;
}

// Draws the line in behind the light, which goes once around from the top
// left. The line is a dash as long as the way around, pulled along so that it
// ends where the light's front is. Each of the light's strokes is a dash that
// ends there too, with a gap after it longer than the way around, so nothing
// shows ahead of the front or wraps past where the line starts. The light fades
// out as the line closes, leaving the line.
function traceIn(perimeter) {
  for (const animation of outline.getAnimations({ subtree: true })) animation.cancel();
  if (reducesMotion.matches) return;
  const trail = Math.min(perimeter * 0.32, 210);
  const whole = `${perimeter}px ${perimeter}px`;
  still.animate(
    [
      { strokeDasharray: whole, strokeDashoffset: `${perimeter}px` },
      { strokeDasharray: whole, strokeDashoffset: "0px" },
    ],
    pass,
  );
  strokes.forEach((stroke, index) => {
    const length = trail * (1 - bands[index].start);
    stroke.style.strokeDasharray = `${length}px ${perimeter * 2}px`;
    stroke.animate([{ strokeDashoffset: `${length}px` }, { strokeDashoffset: `${length - perimeter}px` }], pass);
  });
  outline.classList.add("passing");
  const fade = light.animate(
    [{ opacity: 0 }, { opacity: 1, offset: 0.06 }, { opacity: 1, offset: 0.85 }, { opacity: 0 }],
    pass,
  );
  const done = () => outline.classList.remove("passing");
  fade.addEventListener("finish", done);
  fade.addEventListener("cancel", done);
}

function select(index, { focus = false, lightUp = false } = {}) {
  const changed = index !== selected;
  selected = index;
  tabs.forEach((tab, i) => {
    const isSelected = i === index;
    tab.setAttribute("aria-selected", String(isSelected));
    tab.tabIndex = isSelected ? 0 : -1;
    panels[i].hidden = !isSelected;
  });
  tabs[index].append(outline);
  const perimeter = fit();
  if (focus) tabs[index].focus();
  if (lightUp && changed) traceIn(perimeter);
}

list.setAttribute("role", "tablist");
list.setAttribute("aria-orientation", "vertical");
list.setAttribute("aria-label", "What the agents do");
tabs.forEach((tab, i) => {
  tab.setAttribute("role", "tab");
  panels[i].setAttribute("role", "tabpanel");
  panels[i].setAttribute("aria-labelledby", tab.id);
  // A panel of pictures has nothing to focus, so it takes the focus itself.
  panels[i].tabIndex = 0;
  tab.addEventListener("click", () => select(i, { lightUp: true }));
});

// The arrow keys move between tabs and show each one's picture, and Home and
// End go to the first and the last.
list.addEventListener("keydown", (event) => {
  const current = tabs.indexOf(document.activeElement);
  if (current < 0) return;
  const next = {
    ArrowUp: current - 1,
    ArrowLeft: current - 1,
    ArrowDown: current + 1,
    ArrowRight: current + 1,
    Home: 0,
    End: tabs.length - 1,
  }[event.key];
  if (next === undefined) return;
  event.preventDefault();
  select((next + tabs.length) % tabs.length, { focus: true, lightUp: true });
});

// The tabs change size with the page, and the line follows.
new ResizeObserver(() => fit()).observe(list);

select(0);
workflows.classList.add("ready");
