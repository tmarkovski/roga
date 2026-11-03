// The house from the app, walking. This is the rig and the stride from
// YagaKit/Sources/YagaUI/House/, with the same numbers, so a change to the walk
// there has to be made here too (decision 22). Everything is in the coordinates
// of the mark, where y grows downward and the house faces right.
//
// The page draws the mark's own stride without this script, so someone with no
// JavaScript, or who asked for less motion, sees the house standing still.

const PIVOT = { x: 620, y: 500 };
const FLOOR = 690;
const TOE_WIDTH = 30;
const COMMIT_SPACING = 200;

const REAR_HIP = { x: 560, y: 462 };
const FRONT_HIP = { x: 680, y: 470 };

// Two toes forward and one back for standing on, and all three hanging down for
// a foot in the air, as a direction in degrees and a length.
const SPREAD = [[-14, 80], [22, 92], [148, 56]];
const CURLED = [[58, 62], [96, 66], [150, 56]];

// StrideMotion.push: leaning forward with both legs behind the body.
const STRIDE = {
  duration: 1.25,
  timeDown: 0.66,
  lean: 15,
  offset: { dx: -10, dy: 6 },
  rear: { hip: REAR_HIP, touchdown: -112, liftoff: -204, length: 276, phase: 0 },
  front: { hip: FRONT_HIP, touchdown: -30, liftoff: -122, length: 190, phase: 0.5 },
  stepHeight: 26,
  pitchLanding: -2,
  pitchLeaving: 30,
  pitchInAir: 42,
  rock: { dx: 7, dy: 4, lean: 1.5 },
};

const radians = (degrees) => (degrees * Math.PI) / 180;
const mix = (start, end, amount) => start + (end - start) * amount;
const smooth = (amount) => amount * amount * (3 - 2 * amount);
const arc = (amount) => Math.sin(Math.PI * amount);
const through = (start, middle, end, amount) =>
  amount < 0.5 ? mix(start, middle, smooth(amount * 2)) : mix(middle, end, smooth(amount * 2 - 1));

function placeOnBody(point, lean, offset) {
  const angle = radians(lean);
  const x = point.x - PIVOT.x;
  const y = point.y - PIVOT.y;
  return {
    x: x * Math.cos(angle) - y * Math.sin(angle) + PIVOT.x + offset.dx,
    y: x * Math.sin(angle) + y * Math.cos(angle) + PIVOT.y + offset.dy,
  };
}

function makeFoot(x, lift, pitch, curl) {
  const toes = SPREAD.map(([angle, length], index) => ({
    angle: mix(angle, CURLED[index][0], curl) + pitch * (1 - curl * 0.5),
    length: mix(length, CURLED[index][1], curl),
  }));
  const lowest = Math.max(...toes.map((toe) => toe.length * Math.sin(radians(toe.angle))));
  const ankle = { x, y: FLOOR - TOE_WIDTH / 2 - lowest - lift };
  return {
    ankle,
    curl,
    toes: toes.map((toe) => ({
      x: ankle.x + toe.length * Math.cos(radians(toe.angle)),
      y: ankle.y + toe.length * Math.sin(radians(toe.angle)),
    })),
  };
}

// The knee bends forward and the hock bends back. The leg folds into a zigzag
// when the foot is closer to the hip than the leg is long.
function makeLeg(hip, foot, length, fold) {
  const dx = foot.ankle.x - hip.x;
  const dy = foot.ankle.y - hip.y;
  const distance = Math.hypot(dx, dy);
  const along = { x: dx / distance, y: dy / distance };
  const across = { x: -along.y, y: along.x };
  const depth = -fold * Math.sqrt(Math.max(0, length * length - distance * distance));
  return {
    hip,
    knee: {
      x: hip.x + along.x * distance * 0.36 + across.x * depth,
      y: hip.y + along.y * distance * 0.36 + across.y * depth,
    },
    hock: {
      x: hip.x + along.x * distance * 0.7 - across.x * depth * 0.85,
      y: hip.y + along.y * distance * 0.7 - across.y * depth * 0.85,
    },
    ankle: foot.ankle,
    toes: foot.toes,
  };
}

function stepFoot(leg, hipX, phase) {
  if (phase < STRIDE.timeDown) {
    const amount = phase / STRIDE.timeDown;
    return makeFoot(
      hipX + mix(leg.touchdown, leg.liftoff, amount),
      0,
      mix(STRIDE.pitchLanding, STRIDE.pitchLeaving, amount * amount),
      0,
    );
  }
  const amount = (phase - STRIDE.timeDown) / (1 - STRIDE.timeDown);
  return makeFoot(
    hipX + mix(leg.liftoff, leg.touchdown, smooth(amount)),
    STRIDE.stepHeight * arc(amount),
    through(STRIDE.pitchLeaving, STRIDE.pitchInAir, STRIDE.pitchLanding, amount),
    arc(amount),
  );
}

function walk(time) {
  const cycles = time / STRIDE.duration;
  const phase = cycles - Math.floor(cycles);
  const steps = 4 * Math.PI * phase;
  const wave = Math.sin(steps + 0.5);
  const dip = Math.cos(steps);
  const lean = STRIDE.lean + STRIDE.rock.lean * wave;
  const offset = {
    dx: STRIDE.offset.dx + STRIDE.rock.dx * wave,
    dy: STRIDE.offset.dy + STRIDE.rock.dy * dip,
  };
  // Feet are placed from where the body would be if it didn't rock, so that its
  // rocking doesn't drag them along the floor.
  const leg = (leg) => {
    const hipX = placeOnBody(leg.hip, STRIDE.lean, STRIDE.offset).x;
    const foot = stepFoot(leg, hipX, (phase + leg.phase) % 1);
    return makeLeg(placeOnBody(leg.hip, lean, offset), foot, leg.length, 0.14 + 0.16 * foot.curl);
  };
  const speed = (STRIDE.rear.liftoff - STRIDE.rear.touchdown) / (STRIDE.timeDown * STRIDE.duration);
  return { lean, offset, rear: leg(STRIDE.rear), front: leg(STRIDE.front), floorTravel: speed * time };
}

const house = document.getElementById("house");
const body = document.getElementById("body");
const commits = document.getElementById("commits");
const button = document.getElementById("motion");
const legs = {
  rear: [document.getElementById("rear-bones"), document.getElementById("rear-toes")],
  front: [document.getElementById("front-bones"), document.getElementById("front-toes")],
};

const point = ({ x, y }) => `${x.toFixed(1)} ${y.toFixed(1)}`;

function drawLeg([bones, toes], leg) {
  bones.setAttribute("points", [leg.hip, leg.knee, leg.hock, leg.ankle].map(point).join(" "));
  toes.setAttribute("d", leg.toes.map((toe) => `M${point(leg.ankle)}L${point(toe)}`).join(""));
}

function draw(pose) {
  body.setAttribute(
    "transform",
    `translate(${PIVOT.x + pose.offset.dx} ${PIVOT.y + pose.offset.dy}) rotate(${pose.lean}) translate(${-PIVOT.x} ${-PIVOT.y})`,
  );
  drawLeg(legs.rear, pose.rear);
  drawLeg(legs.front, pose.front);
  commits.setAttribute("stroke-dashoffset", (-pose.floorTravel % COMMIT_SPACING).toFixed(1));
}

const lessMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
let paused = false;
let onScreen = true;
let time = 0;
let lastFrame = null;
let frameRequest = null;

function frame(now) {
  frameRequest = null;
  // A tab that was in the background shouldn't jump forward when it comes back.
  time += lastFrame === null ? 0 : Math.min((now - lastFrame) / 1000, 0.1);
  lastFrame = now;
  draw(walk(time));
  run();
}

function run() {
  if (paused || lessMotion.matches || !onScreen) {
    lastFrame = null;
    return;
  }
  frameRequest ??= requestAnimationFrame(frame);
}

function showButton() {
  button.hidden = lessMotion.matches;
  button.textContent = paused ? "Walk" : "Pause";
}

button.addEventListener("click", () => {
  paused = !paused;
  showButton();
  run();
});

lessMotion.addEventListener("change", () => {
  showButton();
  run();
});

new IntersectionObserver(([entry]) => {
  onScreen = entry.isIntersecting;
  run();
}).observe(house);

showButton();
run();
