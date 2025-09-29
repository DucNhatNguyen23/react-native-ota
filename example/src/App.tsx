import { useEffect, useState } from 'react';
import { Button, Platform, StyleSheet, Text, View } from 'react-native';
import {
  downloadBundle,
  getSavedVersion,
  reloadApp,
  removeBundle,
} from 'react-native-ota';
type responseVersionCode = {
  versionCode: number;
};
const URL = 'http://10.0.2.2:3000';
export default function App() {
  const [status] = useState<string>('');

  const handleReset = async () => {
    try {
      const result = await reloadApp();
      console.log(result);
    } catch (e) {
      console.error(e);
    }
  };

  const handleDownload = async () => {
    try {
      // get version code from server
      // type server response is { versionCode: number }

      const response = await fetch(`${URL}/ota/version`);
      const getVersion: responseVersionCode = await response.json();

      //get saved version code in app
      const savedVersion = getSavedVersion();

      if (savedVersion === getVersion.versionCode) {
        // Already the latest version
        return;
      }

      // url response bundle from server (main.jsbundle.zip for ios, index.android.bundle.zip for android)
      const url = Platform.select({
        android: `${URL}/ota/android-bundle`,
        ios: `${URL}/ota/ios-bundle`,
      });

      // download bundle
      const result = await downloadBundle(url, getVersion.versionCode);

      //if download success, reload app and apply new bundle
      if (result.status) {
        reloadApp();
      }
    } catch (e) {
      console.error(e);
    }
  };
  useEffect(() => {
    handleDownload();
  }, []);
  return (
    <View style={styles.container}>
      <Text>Hello we have a update version!!!!!</Text>
      <Text>status: {status}</Text>
      <Text>version saved code: {getSavedVersion()}</Text>
      <Button title="Reload" onPress={handleReset} />
      <Button title="Remove bundle" onPress={removeBundle} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#fff',
  },
});
