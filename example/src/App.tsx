import { useEffect, useState } from 'react';
import { Button, StyleSheet, Text, View } from 'react-native';
import {
  checkForUpdate,
  getFailedVersion,
  getNativeVersion,
  getSavedVersion,
  reloadApp,
  removeBundle,
} from 'react-native-bundle-ota';

const URL = 'http://10.0.2.2:3000';

export default function App() {
  const [status, setStatus] = useState<string>('');

  useEffect(() => {
    // Also confirms the running bundle works (notifyAppReady), so call it on startup
    checkForUpdate(`${URL}/ota/check`, {
      onProgress: ({ phase, progress }) => {
        setStatus(progress < 0 ? `${phase}...` : `${phase} ${progress}%`);
      },
    })
      .then((result) => {
        if (result.status === 'downloaded') {
          setStatus(`version ${result.update.version} ready on next launch`);
        } else {
          setStatus(result.status);
        }
      })
      .catch((e) => setStatus(`error: ${e.message}`));
  }, []);

  return (
    <View style={styles.container}>
      <Text>Hello we have a update version!!!!!</Text>
      <Text>status: {status}</Text>
      <Text>native version: {getNativeVersion()}</Text>
      <Text>bundle version: {getSavedVersion()}</Text>
      <Text>rolled back version: {getFailedVersion()}</Text>
      <Button title="Reload" onPress={reloadApp} />
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
