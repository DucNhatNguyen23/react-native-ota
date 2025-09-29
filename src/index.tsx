import Ota from './NativeOta';

export function downloadBundle(
  url: string,
  versionCode: number
): Promise<{ status: boolean; message: string }> {
  return Ota.downloadBundle(url, versionCode);
}

export function reloadApp() {
  return Ota.reloadApp();
}
export function getSavedVersion() {
  return Ota.getSavedVersion();
}
export function removeBundle() {
  return Ota.removeBundle();
}
