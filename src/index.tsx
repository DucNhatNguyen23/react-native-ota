import { Platform } from 'react-native';
import Ota, { type DownloadProgress } from './NativeOta';

export type { DownloadProgress };

export type ProgressEvent = Omit<DownloadProgress, 'phase'> & {
  phase: 'download' | 'unzip';
};

// Response body of the check endpoint: { update: UpdateInfo | null }
export type UpdateInfo = {
  version: number;
  url: string;
  sha256?: string;
  // Reload right after download instead of waiting for the next app launch
  mandatory?: boolean;
};

export type CheckForUpdateOptions = {
  headers?: Record<string, string>;
  onProgress?: (event: ProgressEvent) => void;
  // Set to false to handle mandatory updates yourself (e.g. show a dialog first)
  reloadIfMandatory?: boolean;
};

export type CheckForUpdateResult =
  | { status: 'up-to-date' }
  // This version crashed before and was rolled back, it will not be downloaded again
  | { status: 'skipped'; update: UpdateInfo }
  // Applied on next launch, or already reloading if mandatory
  | { status: 'downloaded'; update: UpdateInfo };

export async function checkForUpdate(
  checkUrl: string,
  options: CheckForUpdateOptions = {}
): Promise<CheckForUpdateResult> {
  // JS reached this point, so the running bundle started fine
  notifyAppReady();

  const params = [
    `platform=${Platform.OS}`,
    `nativeVersion=${encodeURIComponent(getNativeVersion())}`,
    `bundleVersion=${getSavedVersion()}`,
  ].join('&');
  const separator = checkUrl.includes('?') ? '&' : '?';
  const response = await fetch(`${checkUrl}${separator}${params}`, {
    headers: options.headers,
  });
  if (!response.ok) {
    throw new Error(`Check for update failed: HTTP ${response.status}`);
  }
  const { update } = (await response.json()) as { update: UpdateInfo | null };

  if (!update || update.version === getSavedVersion()) {
    return { status: 'up-to-date' };
  }
  if (update.version === getFailedVersion()) {
    return { status: 'skipped', update };
  }

  const subscription = options.onProgress
    ? addProgressListener(options.onProgress)
    : null;
  try {
    await downloadBundle(update.url, update.version, update.sha256);
  } finally {
    subscription?.remove();
  }

  if (update.mandatory && options.reloadIfMandatory !== false) {
    await reloadApp();
  }
  return { status: 'downloaded', update };
}

export function downloadBundle(
  url: string,
  versionCode: number,
  sha256?: string
): Promise<{ status: boolean; message: string }> {
  return Ota.downloadBundle(url, versionCode, sha256 ?? null);
}

// Returns a subscription, call `.remove()` to stop listening
export function addProgressListener(listener: (event: ProgressEvent) => void) {
  return Ota.onProgress((event) => listener(event as ProgressEvent));
}

// Marks the running OTA bundle as working. Without it, the next launch rolls back.
// checkForUpdate() calls it for you.
export function notifyAppReady() {
  Ota.notifyAppReady();
}

export function reloadApp() {
  return Ota.reloadApp();
}
export function getSavedVersion() {
  return Ota.getSavedVersion();
}
export function getFailedVersion() {
  return Ota.getFailedVersion();
}
export function getNativeVersion() {
  return Ota.getNativeVersion();
}
export function removeBundle() {
  return Ota.removeBundle();
}
