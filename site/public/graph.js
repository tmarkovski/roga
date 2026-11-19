// Draws a branch graph down the page's left margin, the way the app draws
// history beside commit subjects. Main starts with a commit of its own at the
// top of the first section, and from there each section's heading is a commit
// on main. Each section is something that happens in the repository: agents
// branch off, one branch is reviewed and merged, an agent resolves a merge, and
// main runs into the list of promises at the bottom, ending in a hollow ring
// for what's planned.
//
// Scrolling is time. An invisible tracker sits at a fixed height in the window,
// and a commit lands when the tracker reaches it: the line from the commit
// before runs down into it, and then its dot comes in. A landing plays out on
// its own once it starts, and scrolling back above a commit takes it away
// again. So the graph only ever shows commits that exist and the lines between
// them, and a branch ends at its newest commit, as it would in git at that
// moment.
//
// Landings keep to the order of history. A commit waits until the line into
// the commit before it has arrived, and hurries while others wait behind it,
// so scrolling quickly past several plays them as a quick replay rather than
// all at once. Taking them away goes in the opposite order. Someone who asked
// for less motion gets the whole graph at once, and a margin too narrow for
// it gets no graph, and the list keeps its own line.
//
// The sizes are LaneRenderer's and CommitRowView's, scaled to the margin, and
// the colors are the lanes' Monokai colors (decision 27) from the page's CSS.
//
// It runs in a function of its own, because the page's scripts share one
// global scope and tabs.js already has a reducesMotion and an svg.

(() => {
  const svgNS = "http://www.w3.org/2000/svg";
  const reducesMotion = matchMedia("(prefers-reduced-motion: reduce)");

  // The app's sizes at 1×, in points.
  const app = { spacing: 12, row: 28, dot: 4, ring: 6, line: 1.5, arrow: 3, flatRun: 0.6 };
  const fadedOpacity = 0.35;
  // How far down the window the tracker sits, a third of the way from 60% to
  // the bottom.
  const trackerHeight = 0.73;
  // How long a commit takes to land and to be taken away, in milliseconds. The
  // line runs in over the first part of a landing, and the dot comes in over
  // the last part, a little before the line has quite arrived.
  const landingTime = 1000;
  const leavingTime = 500;
  const lineShare = 0.65;
  const dotFrom = 0.55;
  // How much faster a commit goes while others wait for it.
  const hurry = 3;
  // How long the light takes to go around an agent's merge, once, as on the
  // app's Generate button.
  const lightTime = 1150;

  const sections = Object.fromEntries(
    [...document.querySelectorAll("[data-graph]")].map((section) => [section.dataset.graph, section]),
  );

  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("class", "graph");
  svg.setAttribute("aria-hidden", "true");

  // A line across the margin where the tracker is, for working on the
  // timing. It shows only with ?tracker in the page's address.
  const showsTracker = new URLSearchParams(location.search).has("tracker");
  const guide = document.createElement("div");
  guide.className = "graph-tracker";
  guide.setAttribute("aria-hidden", "true");

  let scene = null;
  let queued = false;

  function element(name, attributes, parent) {
    const node = document.createElementNS(svgNS, name);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    parent?.append(node);
    return node;
  }

  const clamp = (value) => Math.min(1, Math.max(0, value));
  const smooth = (t) => t * t * (3 - 2 * t);
  // Grows a little past full size and settles.
  const pop = (t) => {
    const back = 1.4;
    const u = t - 1;
    return t <= 0 ? 0 : t >= 1 ? 1 : 1 + (back + 1) * u * u * u + back * u * u;
  };
  // Gathers speed leaving the commit before and slows into the new one.
  const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);

  // Where things are on the page, in the document's coordinates.
  function measure() {
    const top = (node) => node.getBoundingClientRect().top + scrollY;
    const bottom = (node) => node.getBoundingClientRect().bottom + scrollY;
    const middleOfFirstLine = (node) => {
      const style = getComputedStyle(node);
      const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.2;
      return top(node) + lineHeight / 2;
    };
    const heading = (section) => middleOfFirstLine(section.querySelector("h2"));
    const { agents, review, assist, mac, replay, promises } = sections;
    return {
      left: promises.querySelector(".wide").getBoundingClientRect().left + scrollX,
      rem: parseFloat(getComputedStyle(document.documentElement).fontSize),
      agents: { top: top(agents.querySelector(".wide")), heading: heading(agents) },
      review: { heading: heading(review), bottom: bottom(review.querySelector("img")) },
      assist: { heading: heading(assist) },
      mac: { heading: heading(mac), bottom: bottom(mac.querySelector(".compare-labels")) },
      replay: { top: top(replay), heading: heading(replay), bottom: bottom(replay) },
      items: [...promises.querySelectorAll("li")].map(middleOfFirstLine),
    };
  }

  // Four columns, then two columns' room before the text, and half a column
  // spare at the window's edge for a ring.
  function geometry(page) {
    // Smaller than the app's own size, it's squeezed against the window's
    // edge, so it's left out.
    const spacing = Math.min(16, (page.left - 12) / 5.5);
    if (spacing < 11) return null;
    const k = spacing / app.spacing;
    const first = page.left - 5 * spacing;
    const row = app.row * k;
    return {
      col: (column) => first + column * spacing,
      // The list's own dots are 0.75rem across, at its left edge.
      list: page.left + 0.375 * page.rem,
      row,
      half: row / 2,
      dot: app.dot * k,
      ring: app.ring * k,
      line: app.line * k,
      arrow: app.arrow * k,
    };
  }

  // The history, as lanes. Each lane is a run of segments, each ending at the
  // commit, merge or cut whose landing shows it, and its dots.
  function story(page, g) {
    const heads = [];

    function lane(color) {
      return { color, x: 0, y: 0, d: "", drawn: false, segments: [], dots: [], work: null };
    }

    function begin(l, x, y) {
      Object.assign(l, { x, y, from: y, d: `M${x} ${y}`, drawn: false });
    }

    // Ends the segment drawn so far at a checkpoint, and starts the next one
    // there. A segment remembers the checkpoint it starts from too, so that it
    // waits for that one to land first.
    function land(l, y) {
      if (l.drawn) l.segments.push({ d: l.d, from: l.from, at: y });
      Object.assign(l, { from: y, d: `M${l.x} ${y}`, drawn: false });
    }

    function down(l, y) {
      if (y <= l.y) return;
      l.d += `L${l.x} ${y}`;
      Object.assign(l, { y, drawn: true });
    }

    function commit(l, y, more = {}) {
      down(l, y);
      land(l, y);
      const dot = { x: l.x, y, color: l.color, ...more };
      l.dots.push(dot);
      return dot;
    }

    // A commit on main, which HEAD moves to once it has landed.
    function head(l, y, more) {
      const dot = commit(l, y, more);
      heads.push(dot);
      return dot;
    }

    // A branch leaves its parent sideways and turns down into its column by
    // the next row, as LaneRenderer draws a line leaving a dot.
    function fork(parent, y, child, column) {
      const x0 = parent.x;
      const x1 = g.col(column);
      begin(child, x0, y);
      child.d += `C${x0 + (x1 - x0) * app.flatRun} ${y} ${x1} ${y} ${x1} ${y + g.half}`;
      Object.assign(child, { x: x1, y: y + g.half, drawn: true });
    }

    // A branch comes down its column and into the merge from the right, and
    // its last segment lands with the merge.
    function merge(l, into, y, more) {
      down(l, y - g.half);
      const x0 = l.x;
      const x1 = into.x;
      l.d += `C${x0} ${y} ${x1 + (x0 - x1) * app.flatRun} ${y} ${x1} ${y}`;
      Object.assign(l, { y, drawn: true });
      land(l, y);
      return head(into, y, more);
    }

    // A lane moves over away from any dot, leaving and arriving straight down.
    function move(l, x1, from, span = g.row) {
      const y = Math.max(from, l.y);
      down(l, y);
      const x0 = l.x;
      const middle = y + span / 2;
      l.d += `C${x0} ${middle} ${x1} ${middle} ${x1} ${y + span}`;
      Object.assign(l, { x: x1, y: y + span, drawn: true });
    }

    // A line cut short ends in an arrow pointing the way it goes on. The arrow
    // is part of the segment, so it's drawn last, as the line gets there.
    function cut(l, y) {
      down(l, y);
      const a = g.arrow;
      l.d += `M${l.x - a} ${y - a}L${l.x} ${y}L${l.x + a} ${y - a}`;
      land(l, y);
    }

    // Commits at fractions of a stretch, leaving out any that would crowd the
    // one before. It gives the height of the last.
    function commits(l, from, to, fractions) {
      let last = l.y;
      for (const f of fractions) {
        const y = from + (to - from) * f;
        if (y - last < g.row * 0.75) continue;
        commit(l, y);
        last = y;
      }
      return last;
    }

    const { agents, review, assist, mac, replay, items } = page;
    const { row, half } = g;
    const main = lane(0);
    const reviewed = lane(1);
    const resolved = lane(2);
    const third = lane(3);
    const next = lane(4);

    // Main's first commit is alone, at the top of the first section's
    // content, beside the top of its picture. When the picture goes under the
    // text, it stays two rows above the heading, so that it doesn't crowd it.
    // Three agents then branch off while the heading is read, each in a
    // worktree of its own.
    const start = Math.min(agents.top, agents.heading - 2 * row);
    const forks = [agents.heading, agents.heading + 2 * row, agents.heading + 4 * row];
    begin(main, g.col(0), start);
    head(main, start);
    for (const y of forks) head(main, y);
    fork(main, forks[0], reviewed, 1);
    fork(main, forks[1], resolved, 2);
    fork(main, forks[2], third, 3);

    // An agent works until its last commit lands. The first makes the four
    // commits that get reviewed, and stops. Its branch is merged beside the
    // bottom of its diff.
    const merged = review.bottom - 2 * row;
    reviewed.work = commits(reviewed, reviewed.y, review.heading - row, [0.16, 0.4, 0.64, 0.9]);

    // The others work on through the review, then step left a column once the
    // reviewed branch is merged, as lanes do in the app.
    const conflict = assist.heading;
    commits(resolved, resolved.y, merged - row, [0.12, 0.3, 0.52, 0.71, 0.9]);
    move(resolved, g.col(1), merged + half);
    resolved.work = commits(resolved, resolved.y, conflict - 2 * row, [0.35, 0.8]);

    const lastMerge = mac.bottom + 1.5 * row;
    commits(third, third.y, merged - row, [0.2, 0.44, 0.66, 0.88]);
    move(third, g.col(2), merged + half);
    commits(third, third.y, conflict, [0.3, 0.62, 0.92]);
    move(third, g.col(1), conflict + half);
    third.work = commits(third, third.y, lastMerge - 2 * row, [0.2, 0.42, 0.63, 0.85]);

    // Main: a commit at each heading, the reviewed branch merged under its
    // diff, the conflict an agent resolved, and the last agent's work. The
    // tall sections have another commit halfway to the next one, so that no
    // line has too far to run when it lands.
    head(main, review.heading);
    merge(reviewed, main, merged);
    merge(resolved, main, conflict, { agent: true });
    head(main, (conflict + mac.heading) / 2);
    head(main, mac.heading);
    head(main, (mac.heading + lastMerge) / 2);
    merge(third, main, lastMerge);

    // The replay is coming in the next release, so its branch isn't merged
    // yet, and it goes on past the band.
    const turn = Math.min(replay.bottom - row, items[0] - 4 * row);
    head(main, replay.heading);
    fork(main, replay.heading, next, 1);
    head(main, Math.min((replay.heading + items[0]) / 2, turn - row));
    commits(next, next.y, turn - 2 * row, [0.25, 0.55, 0.85]);
    cut(next, turn - row);

    // Main moves over into the list's own line, and its items are the last
    // commits. What's planned hasn't happened, so it's a hollow ring.
    move(main, g.list, turn, items[0] - 0.75 * row - turn);
    items.slice(0, -1).forEach((y) => head(main, y));
    commit(main, items.at(-1), { hollow: true });

    // During the review, everything but the branch under review fades, as
    // commits the checked-out branch is missing do in the app.
    const fade = { from: review.heading - 1.5 * row, to: merged - row, ramp: 1.5 * row, keep: reviewed };

    return {
      heads: heads.sort((a, b) => a.y - b.y),
      fade,
      band: [replay.top, replay.bottom],
      end: items.at(-1),
      order: [next, third, resolved, reviewed, main],
    };
  }


  // The checkpoints, one for each height where something lands: a commit, a
  // merge or the end of a cut line. Each knows the checkpoints its lines start
  // from and the ones they lead on to, how far it has landed, from 0 to 1, and
  // whether the tracker has passed it.
  function checkpoints(history) {
    const byHeight = new Map();
    const at = (y) => {
      if (!byHeight.has(y)) byHeight.set(y, { y, p: 0, target: 0, before: [], after: [], lit: null });
      return byHeight.get(y);
    };
    for (const l of history.order) {
      for (const dot of l.dots) at(dot.y);
      for (const segment of l.segments) {
        const from = at(segment.from);
        const to = at(segment.at);
        to.before.push(from);
        from.after.push(to);
      }
    }
    return { at, all: [...byHeight.values()] };
  }

  // How far the line into a checkpoint has run, and how far its dot has come in.
  const lineOf = (point) => easeInOut(clamp(point.p / lineShare));
  const dotOf = (point) => pop(clamp((point.p - dotFrom) / (1 - dotFrom)));

  // Draws the history once into a layer. The band in the middle of the page is
  // dark, so the history is drawn twice, and the copy over the band takes the
  // dark appearance's colors.
  function draw(layer, history, g, at) {
    const parts = { groups: new Map(), segments: [], dots: [], heads: [], agents: [], lights: [] };

    for (const l of history.order) {
      const group = element("g", { class: "graph-lane", style: `--c: var(--lane-${l.color})` }, layer);
      parts.groups.set(l, group);

      for (const segment of l.segments) {
        const node = element("path", { class: "graph-line", d: segment.d, "stroke-width": g.line }, group);
        const length = node.getTotalLength();
        node.setAttribute("stroke-dasharray", `${length} ${length}`);
        parts.segments.push({ point: at(segment.at), node, length, last: -1 });
      }

      for (const dot of l.dots) {
        const point = at(dot.y);
        if (dot.agent) {
          // The line the app draws around an agent's work (decision 68), and
          // its light, which goes around once as the merge lands.
          const r = g.ring + 2.5 * g.line;
          const outline = element("circle", { class: "graph-agent", cx: dot.x, cy: dot.y, r: 0, "stroke-width": g.line }, group);
          const light = element("circle", { class: "graph-agent-light", cx: dot.x, cy: dot.y, r, "stroke-width": g.line * 1.4 }, group);
          const around = 2 * Math.PI * r;
          light.setAttribute("stroke-dasharray", `${around * 0.25} ${around}`);
          parts.lights.push({ point, outline, light, r, around });
        }
        const node = element("circle", { class: dot.hollow ? "graph-hollow" : "graph-dot", cx: dot.x, cy: dot.y, r: 0 }, group);
        if (dot.hollow) node.setAttribute("stroke-width", g.line);
        parts.dots.push({ dot, point, node, last: -1 });
      }

      // The ring of an agent at work (decision 46), on its branch's newest
      // commit: a gray ring with an orange quarter from the top. It stands
      // still, as the design canvas draws it, rather than turning as in the
      // sidebar, because a ring turning beside the text would keep catching
      // the eye of someone reading it. Lines stop at it, as at HEAD's ring.
      if (l.work !== null) {
        const r = g.ring;
        const ring = element("g", { style: "display: none" }, group);
        element("circle", { class: "graph-knock", r }, ring);
        element("circle", { class: "graph-dot", r: g.dot }, ring);
        element("circle", { class: "graph-track", r, "stroke-width": g.line }, ring);
        element("path", { class: "graph-arc", d: `M0 ${-r}A${r} ${r} 0 0 1 ${r} 0`, "stroke-width": g.line }, ring);
        const commits = l.dots.map((dot) => ({ dot, point: at(dot.y) }));
        parts.agents.push({ lane: l, commits, node: ring, last: "" });
      }
    }

    // HEAD's ring, on the newest commit on main. Lines stop at the ring, which
    // leaves a gap around the dot.
    for (const dot of history.heads) {
      const ring = element("g", { style: `--c: var(--lane-${dot.color})` }, layer);
      const knock = element("circle", { class: "graph-knock", cx: dot.x, cy: dot.y, r: 0 }, ring);
      const inner = element("circle", { class: "graph-dot", cx: dot.x, cy: dot.y, r: 0 }, ring);
      const outer = element("circle", { class: "graph-head", cx: dot.x, cy: dot.y, r: 0, "stroke-width": g.line }, ring);
      parts.heads.push({ point: at(dot.y), knock, inner, outer, last: -1 });
    }
    return parts;
  }

  function build() {
    const page = measure();
    const g = geometry(page);
    svg.replaceChildren();
    if (!g) {
      svg.remove();
      guide.remove();
      document.documentElement.classList.remove("graph-on");
      scene = null;
      return;
    }

    const history = story(page, g);
    const width = page.left + 2 * page.rem;
    const height = history.end + 2 * g.row;
    svg.setAttribute("width", width);
    svg.setAttribute("height", height);
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    // On the page before drawing, so that the lines can be measured.
    if (!svg.isConnected) document.body.prepend(svg);
    if (showsTracker) {
      guide.style.width = `${page.left - page.rem}px`;
      if (!guide.isConnected) document.body.append(guide);
    }

    const defs = element("defs", {}, svg);
    const [bandTop, bandBottom] = history.band;
    const offBand = element("clipPath", { id: "graph-off-band" }, defs);
    element("path", { "clip-rule": "evenodd", d: `M0 0H${width}V${height}H0Z M0 ${bandTop}H${width}V${bandBottom}H0Z` }, offBand);
    const onBand = element("clipPath", { id: "graph-on-band" }, defs);
    element("rect", { x: 0, y: bandTop, width, height: bandBottom - bandTop }, onBand);

    const layers = [
      element("g", { "clip-path": "url(#graph-off-band)" }, svg),
      element("g", { class: "graph-band", "clip-path": "url(#graph-on-band)" }, svg),
    ];
    const points = checkpoints(history);
    scene = { g, history, points, copies: layers.map((layer) => draw(layer, history, g, points.at)) };
    document.documentElement.classList.add("graph-on");
    // What the tracker has already passed when the page loads or changes size
    // is there at once, without playing.
    retarget({ settle: true });
  }

  // How far down the page the tracker is. Near the bottom, it speeds up a
  // little if it would otherwise stop short of the last commit.
  function tracker() {
    if (reducesMotion.matches) return Infinity;
    const root = document.documentElement;
    const furthest = Math.max(1, root.scrollHeight - innerHeight);
    const reach = furthest + innerHeight * trackerHeight;
    const short = Math.max(0, scene.history.end + scene.g.row - reach);
    return scrollY + innerHeight * trackerHeight + short * clamp(scrollY / furthest);
  }

  // Works out what the tracker has passed, and plays whatever has to land or
  // be taken away.
  function retarget({ settle = false } = {}) {
    scrollQueued = false;
    if (!scene) return;
    const y = tracker();
    const still = settle || reducesMotion.matches;
    guide.hidden = !Number.isFinite(y);
    if (!guide.hidden) guide.style.top = `${y - scrollY}px`;
    for (const point of scene.points.all) {
      point.target = y >= point.y ? 1 : 0;
      if (still) point.p = point.target;
    }

    // During the review, everything but the branch under review fades, as
    // commits the checked-out branch is missing do in the app.
    const { fade } = scene.history;
    const faded = y >= fade.from && y < fade.to;
    svg.classList.toggle("graph-settling", still);
    for (const parts of scene.copies) {
      for (const [l, group] of parts.groups) {
        group.style.opacity = faded && l !== fade.keep ? fadedOpacity : "";
      }
    }

    if (still) render(performance.now());
    else play();
  }

  let playing = false;
  let then = 0;

  function play() {
    if (playing) return;
    playing = true;
    then = performance.now();
    requestAnimationFrame(step);
  }

  // Moves every checkpoint toward where it should be. One that's landing
  // waits for the lines into the checkpoints before it, and one that's being
  // taken away waits for the checkpoints after it to go first.
  function step(now) {
    if (!scene) {
      playing = false;
      return;
    }
    const elapsed = Math.min(64, now - then);
    then = now;
    let moving = false;
    for (const point of scene.points.all) {
      if (point.p === point.target) continue;
      moving = true;
      if (point.target > point.p) {
        if (!point.before.every((before) => before.p >= lineShare)) continue;
        const waiting = point.after.some((after) => after.target === 1);
        point.p = Math.min(1, point.p + (elapsed / landingTime) * (waiting ? hurry : 1));
        if (point.p === 1) point.lit = now;
      } else {
        if (!point.after.every((after) => after.p === 0)) continue;
        const waiting = point.before.some((before) => before.target === 0);
        point.p = Math.max(0, point.p - (elapsed / leavingTime) * (waiting ? hurry : 1));
        point.lit = null;
      }
    }
    const lighting = render(now);
    if (moving || lighting) requestAnimationFrame(step);
    else playing = false;
  }

  // Draws every checkpoint as far as it has got. It says whether a light is
  // still going around.
  function render(now) {
    const { g } = scene;
    let lighting = false;

    for (const parts of scene.copies) {
      // A line that hasn't started is hidden, because a round cap would show
      // as a dot at its start.
      for (const item of parts.segments) {
        const t = lineOf(item.point);
        if (t === item.last) continue;
        item.last = t;
        item.node.style.visibility = t > 0 ? "" : "hidden";
        item.node.setAttribute("stroke-dashoffset", item.length * (1 - t));
      }

      for (const item of parts.dots) {
        const r = (item.dot.hollow ? g.dot + g.line / 2 : g.dot) * dotOf(item.point);
        if (r === item.last) continue;
        item.last = r;
        item.node.setAttribute("r", r);
      }

      for (const item of parts.lights) {
        item.outline.setAttribute("r", item.r * dotOf(item.point));
        const t = item.point.lit === null ? 1 : clamp((now - item.point.lit) / lightTime);
        if (t < 1) lighting = true;
        item.light.setAttribute("stroke-dashoffset", -item.around * easeInOut(t));
        item.light.style.opacity = t < 1 ? 1 - smooth(clamp((t - 0.7) / 0.3)) : 0;
      }

      // An agent's ring sits on its newest commit until its last one lands.
      for (const agent of parts.agents) {
        const newest = agent.commits.findLast(({ point }) => dotOf(point) > 0);
        const scale = newest && newest.dot.y < agent.lane.work ? dotOf(newest.point) : 0;
        const place = scale > 0 ? `translate(${newest.dot.x} ${newest.dot.y}) scale(${scale})` : "";
        if (place === agent.last) continue;
        agent.last = place;
        agent.node.style.display = place ? "" : "none";
        if (place) agent.node.setAttribute("transform", place);
      }

      // Each commit's ring comes in as it lands and goes as the next one
      // lands, so taking that one away hands it back.
      parts.heads.forEach((item, index) => {
        const next = parts.heads[index + 1];
        const leaving = next ? smooth(clamp(dotOf(next.point))) : 0;
        const scale = dotOf(item.point) * (1 - leaving);
        if (scale === item.last) return;
        item.last = scale;
        item.knock.setAttribute("r", g.ring * scale);
        item.inner.setAttribute("r", g.dot * scale);
        item.outer.setAttribute("r", g.ring * scale);
      });
    }
    return lighting;
  }

  let scrollQueued = false;
  function queue() {
    if (!scrollQueued) {
      scrollQueued = true;
      requestAnimationFrame(() => retarget());
    }
  }

  let buildQueued = false;
  function queueBuild() {
    if (buildQueued) return;
    buildQueued = true;
    requestAnimationFrame(() => {
      buildQueued = false;
      build();
    });
  }

  build();
  addEventListener("scroll", queue, { passive: true });
  addEventListener("resize", queueBuild);
  new ResizeObserver(queueBuild).observe(document.body);
  reducesMotion.addEventListener("change", () => retarget());
})();
