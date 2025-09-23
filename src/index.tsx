import Ota from './NativeOta';

export function downloadBundle(url: string): Promise<boolean> {
  return Ota.downloadBundle(url);
}

export function reloadApp() {
  return Ota.reloadApp();
}
