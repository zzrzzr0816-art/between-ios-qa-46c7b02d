import { execFileSync, spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { CompanionSupervisor } from './src/server/companion/supervisor.ts';
import { listBootedSims } from './src/server/companion/discovery.ts';
import { IdbClient } from './src/server/idb/client.ts';

type AxNode = {
  AXLabel?: string;
  type?: string;
  frame?: { x: number; y: number; width: number; height: number };
  children?: AxNode[];
};

function flatten(nodes: AxNode[]): AxNode[] {
  return nodes.flatMap(node => [node, ...flatten(node.children ?? [])]);
}

const app = process.env.BETWEEN_APP;
const evidence = process.env.BETWEEN_EVIDENCE;
const screenshotCheck = process.env.BETWEEN_SCREENSHOT_CHECK;
if (!app || !evidence || !screenshotCheck) throw new Error('The app, evidence and screenshot checker paths are required');
const sims = await listBootedSims();
const udid = process.env.BETWEEN_SIMULATOR_UDID;
const sim = udid ? sims.find(device => device.udid === udid) : sims[0];
if (!sim) throw new Error('No booted iOS simulator');

const bundle = 'com.example.between.preview';
function simctl(...args: string[]) {
  execFileSync('xcrun', ['simctl', ...args], { stdio: 'inherit', timeout: 90_000 });
}

const supervisor = new CompanionSupervisor();
const client = IdbClient.connect(await supervisor.socketFor(sim.udid));
let hidError: Error | undefined;
const hid = client.openHid(error => { hidError = error; });
let lastTree = '';
let recording: ReturnType<typeof spawn> | undefined;
let recordingFinished: Promise<void> | undefined;
try {
  simctl('install', sim.udid, app);
  simctl('launch', '--terminate-running-process', sim.udid, bundle,
    '-preview-fixture', '-ui-verify-companions');
  recording = spawn('xcrun', ['simctl', 'io', sim.udid, 'recordVideo', '--codec=h264',
    join(evidence, 'between-interactions.mp4')], { stdio: 'inherit' });
  recordingFinished = new Promise(resolve => {
    recording!.once('close', () => resolve());
    recording!.once('error', error => { console.warn(error); resolve(); });
  });

  const waitFor = async (step: string, check: (labels: Set<string>) => boolean) => {
    const deadline = Date.now() + 25_000;
    while (Date.now() < deadline) {
      if (hidError) throw hidError;
      try { lastTree = await client.accessibilityInfo(); }
      catch { await delay(300); continue; }
      const labels = new Set(flatten(JSON.parse(lastTree) as AxNode[]).map(node => node.AXLabel ?? ''));
      if (check(labels)) {
        console.log(step);
        return;
      }
      await delay(300);
    }
    throw new Error('Timed out: ' + step);
  };

  function hasRole(labels: Set<string>, side: string) {
    return labels.has('QA ' + side + ' companion');
  }
  const both = (labels: Set<string>) => hasRole(labels, 'devil') && hasRole(labels, 'angel');
  await waitFor('Initial story and both roles', labels => labels.has('1 / 5') && both(labels));
  const { width, height } = await client.uiSize() ?? (await client.describe()).screen;

  function screenshot(name: string, roles: string[]) {
    const path = join(evidence!, name + '.png');
    simctl('io', sim.udid, 'screenshot', path);
    const nodes = flatten(JSON.parse(lastTree) as AxNode[]);
    for (const side of roles) {
      const probe = nodes.find(node => node.AXLabel === 'QA ' + side + ' companion')?.frame;
      if (!probe) throw new Error('Companion position is missing: ' + side);
      execFileSync(screenshotCheck!, [path, String(width), String(height),
        String(probe.x), String(probe.y), String(probe.width), String(probe.height), side],
        { stdio: 'inherit', timeout: 10_000 });
    }
  }

  const swipe = async (startX: number, startY: number, dx: number, dy: number) => {
    hid.touch('down', startX, startY);
    for (let i = 1; i <= 8; i++) {
      hid.touch('move', startX + dx * i / 8, startY + dy * i / 8);
      await delay(20);
    }
    hid.touch('up', startX + dx, startY + dy);
  };
  const tap = async (x: number, y: number) => {
    hid.touch('down', x, y);
    await delay(60);
    hid.touch('up', x, y);
  };
  const tapLabel = async (label: string, contains = false) => {
    await waitFor('Control available: ' + label, labels => contains
      ? [...labels].some(value => value.includes(label)) : labels.has(label));
    const nodes = flatten(JSON.parse(lastTree) as AxNode[]);
    const frame = nodes.find(node => node.frame && (contains ? node.AXLabel?.includes(label) : node.AXLabel === label))?.frame;
    if (!frame) throw new Error('Control not found: ' + label);
    await tap(frame.x + frame.width / 2, frame.y + frame.height / 2);
  };

  const tapTextArea = async () => {
    const nodes = flatten(JSON.parse(lastTree) as AxNode[]);
    const frame = nodes.find(node => node.type === 'TextArea' && node.frame)?.frame;
    if (!frame) throw new Error('No visible text area on the current screen');
    await tap(frame.x + frame.width / 2, frame.y + frame.height / 2);
  };

  const companionPosition = (side: string) =>
    flatten(JSON.parse(lastTree) as AxNode[]).find(node => node.AXLabel === 'QA ' + side + ' companion')?.frame;
  const initialPositions = ['angel','devil'].map(companionPosition);
  for (const [index, direction] of [[2,-1],[3,-1],[4,-1],[5,-1],[4,1],[3,1],[2,1],[1,1]]) {
    await swipe(width * 0.5, height * 0.55, 0, direction * height * 0.24);
    await waitFor('Continuous feed gesture to ' + index,
      labels => labels.has(index + ' / 5') && both(labels));
    for (const [role, side] of ['angel','devil'].entries()) {
      const initial = initialPositions[role];
      const position = companionPosition(side);
      if (!initial || !position || Math.abs(initial.y - position.y) > 1) {
        throw new Error(side + ' companion changed height during a feed page turn');
      }
    }
    await delay(160);
  }
  await swipe(width * 0.5, height * 0.51, -width * 0.12, 0);
  await delay(420);
  await waitFor('Short horizontal swipe restores both roles',
    labels => both(labels) && !labels.has('The conversation'));
  screenshot('home-after-swipes', ['angel','devil']);

  for (const side of ['devil','angel']) {
    const direction = side === 'angel' ? -1 : 1;
    await swipe(width * 0.5, height * 0.51, direction * width * 0.39, 0);
    await waitFor(side + ' discussion keeps only the selected companion',
      labels => labels.has('The conversation') && hasRole(labels,side) && !both(labels) && !labels.has('Post'));
    await tapTextArea();
    await waitFor(side + ' discussion keyboard and selected role',
      labels => labels.has('QA keyboard visible') && hasRole(labels,side) && !both(labels));
    screenshot(side + '-keyboard', [side]);
    await tapLabel('Back');
    await waitFor(side + ' discussion closes and restores both roles',
      labels => both(labels) && labels.has('Me') && !labels.has('QA keyboard visible') && !labels.has('The conversation'));
  }

  await tapLabel('Me');
  await waitFor('Profile keeps both companions', labels => [...labels].some(label => label.includes('My stories')) && !labels.has('Close') && labels.has('Stories') && both(labels));
  screenshot('profile', ['angel','devil']);
  await tapLabel('My stories', true);
  await waitFor('My stories keeps both companions', labels => labels.has('My stories') && labels.has('Back') && !labels.has('Close') && labels.has('Stories') && both(labels));
  screenshot('my-stories', ['angel','devil']);
  await tapLabel('Stories');
  await waitFor('Profile return restores home without a feed gesture', labels => labels.has('1 / 5') && labels.has('Me') && both(labels));
  screenshot('home-after-profile', ['angel','devil']);

  await tapLabel('My best friend is moving away. Do I tell them how much it hurts?');
  await waitFor('Open story detail', labels => labels.has('View angel responses'));
  await swipe(width * 0.5, height * 0.51, -width * 0.39, 0);
  await delay(400);
  await waitFor('Story detail horizontal swipe stays on detail', labels => labels.has('View angel responses') && !labels.has('The conversation'));
  await tapLabel('View angel responses');
  await waitFor('Companion opens the same angel discussion', labels => labels.has('The conversation') && hasRole(labels,'angel') && !hasRole(labels,'devil'));
  // The destination can appear in the accessibility tree before the panel
  // finishes its 340 ms entrance and accepts a new gesture.
  await delay(400);
  await swipe(width * 0.5, height * 0.51, width * 0.39, 0);
  await waitFor('Swiping discussion closed returns to the expanded story', labels => labels.has('View angel responses') && !labels.has('The conversation'));
  await tapLabel('Back');
  await waitFor('Home after closing story detail', labels => labels.has('1 / 5') && both(labels));
  await swipe(width * 0.5, height * 0.51, -width * 0.39, 0);
  await waitFor('Discussion ready to open a reply', labels => labels.has('Reply') && hasRole(labels,'angel'));
  await tapLabel('Reply');
  await waitFor('Reply card shows only its own composer and camp', labels => labels.has('Back to comments') && labels.has('Write a reply…') && !labels.has('Say something kind…') && hasRole(labels,'angel') && !hasRole(labels,'devil'));
  await tapLabel('Back to comments');
  await waitFor('Reply card closes back to discussion', labels => labels.has('The conversation') && !labels.has('Back to comments'));
  await tapLabel('Back');
  await waitFor('Home after dismissing reply', labels => labels.has('1 / 5') && both(labels));

  await tapLabel('More');
  await waitFor('More sheet is operable', labels => labels.has('Companion motion') && labels.has('Close'));
  await tapLabel('Close');
  await waitFor('Home after dismissing More', labels => labels.has('1 / 5') && both(labels));

  await tapLabel('Post');
  await waitFor('Write sheet and one role', labels =>
    labels.has("What's on your mind?") && labels.has('Story text') && hasRole(labels,'devil') !== hasRole(labels,'angel'));
  await tapLabel('Story text');
  await waitFor('Write keyboard and one role', labels =>
    labels.has('QA keyboard visible') && hasRole(labels,'devil') !== hasRole(labels,'angel'));
  const writeRole = flatten(JSON.parse(lastTree) as AxNode[]).some(node => node.AXLabel === 'QA devil companion') ? 'devil' : 'angel';
  screenshot('write-keyboard', [writeRole]);
  await tapLabel('Close');
  await waitFor('Closing write sheet restores home and both roles',
    labels => both(labels) && !labels.has('QA keyboard visible') && labels.has('1 / 5'));
  screenshot('home-after-keyboard', ['angel','devil']);
} catch (error) {
  writeFileSync(join(evidence, 'last-accessibility.json'), lastTree);
  try { simctl('io', sim.udid, 'screenshot', join(evidence,'failure.png')); } catch {}
  throw error;
} finally {
  if (recording && recordingFinished) {
    recording.kill('SIGINT');
    const deadline = setTimeout(() => recording?.kill('SIGKILL'), 15_000);
    await recordingFinished;
    clearTimeout(deadline);
  }
  hid.end();
  client.close();
  supervisor.stopAll();
}
