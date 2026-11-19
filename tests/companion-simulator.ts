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
  recording = spawn('xcrun', ['simctl', 'io', sim.udid, 'recordVideo', '--codec=h264',
    join(evidence, 'between-interactions.mp4')], { stdio: 'inherit' });
  recordingFinished = new Promise(resolve => {
    recording!.once('close', () => resolve());
    recording!.once('error', error => { console.warn(error); resolve(); });
  });

  const launch = () => simctl('launch', '--terminate-running-process', sim.udid, bundle,
    '-preview-fixture', '-ui-verify-companions');
  try { launch(); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ETIMEDOUT') throw error;
    console.warn('Simulator launch timed out; retrying once');
    launch();
  }

  // Use the workflow's fixed iPhone 16 fixture and wait between recorded actions.
  const tap = async (x: number, y: number, pause = 1100) => {
    if (hidError) throw hidError;
    hid.touch('down', x, y);
    await delay(75);
    hid.touch('up', x, y);
    await delay(pause);
  };
  await delay(2800);
  await tap(311, 782); // Me
  await tap(91, 315);  // My stories
  await tap(82, 782);  // Stories tab
  await tap(196, 386); // Expand the story
  await tap(370, 420); // Angel companion opens the discussion
  await tap(37, 103);  // Return to story
  await tap(33, 87);   // Close story
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
