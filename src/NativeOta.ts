import { TurboModuleRegistry, type TurboModule } from 'react-native';

export interface Spec extends TurboModule {
  downloadBundle(url: string): Promise<boolean>;
  reloadApp(): Promise<string>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Ota');
