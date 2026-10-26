import Ota from '../NativeOta';
import { checkForUpdate } from '../index';

jest.mock('../NativeOta', () => ({
  __esModule: true,
  default: {
    downloadBundle: jest.fn(),
    reloadApp: jest.fn(),
    getSavedVersion: jest.fn(),
    getFailedVersion: jest.fn(),
    getNativeVersion: jest.fn(),
    notifyAppReady: jest.fn(),
    removeBundle: jest.fn(),
    onProgress: jest.fn(),
  },
}));

const mockOta = jest.mocked(Ota);

const update = { version: 6, url: 'https://cdn/6.zip', sha256: 'abc' };

function mockServer(body: unknown, status = 200) {
  global.fetch = jest.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
  }) as jest.Mock;
}

beforeEach(() => {
  jest.clearAllMocks();
  mockOta.getSavedVersion.mockReturnValue(5);
  mockOta.getFailedVersion.mockReturnValue(0);
  mockOta.getNativeVersion.mockReturnValue('1.2.0(15)');
  mockOta.downloadBundle.mockResolvedValue({ status: true, message: '' });
  mockOta.onProgress.mockReturnValue({ remove: jest.fn() });
});

it('confirms the running bundle and sends versions to the server', async () => {
  mockServer({ update: null });

  await expect(checkForUpdate('https://api/ota/check')).resolves.toEqual({
    status: 'up-to-date',
  });

  expect(mockOta.notifyAppReady).toHaveBeenCalled();
  expect(global.fetch).toHaveBeenCalledWith(
    'https://api/ota/check?platform=ios&nativeVersion=1.2.0(15)&bundleVersion=5',
    { headers: undefined }
  );
  expect(mockOta.downloadBundle).not.toHaveBeenCalled();
});

it('appends params to a url that already has a query string', async () => {
  mockServer({ update: null });

  await checkForUpdate('https://api/ota/check?app=demo');

  expect((global.fetch as jest.Mock).mock.calls[0][0]).toContain(
    'check?app=demo&platform='
  );
});

it('treats the installed version as up to date', async () => {
  mockServer({ update: { ...update, version: 5 } });

  await expect(checkForUpdate('https://api/check')).resolves.toEqual({
    status: 'up-to-date',
  });
  expect(mockOta.downloadBundle).not.toHaveBeenCalled();
});

it('treats a decimal version as up to date once installed', async () => {
  mockOta.getSavedVersion.mockReturnValue(12.1);
  mockServer({ update: { ...update, version: 12.1 } });

  await expect(checkForUpdate('https://api/check')).resolves.toEqual({
    status: 'up-to-date',
  });
  expect(mockOta.downloadBundle).not.toHaveBeenCalled();
});

it('skips a version that was rolled back', async () => {
  mockOta.getFailedVersion.mockReturnValue(6);
  mockServer({ update });

  await expect(checkForUpdate('https://api/check')).resolves.toEqual({
    status: 'skipped',
    update,
  });
  expect(mockOta.downloadBundle).not.toHaveBeenCalled();
});

it('downloads with sha256 and does not reload a non-mandatory update', async () => {
  mockServer({ update });

  await expect(checkForUpdate('https://api/check')).resolves.toEqual({
    status: 'downloaded',
    update,
  });
  expect(mockOta.downloadBundle).toHaveBeenCalledWith(
    'https://cdn/6.zip',
    6,
    'abc'
  );
  expect(mockOta.reloadApp).not.toHaveBeenCalled();
});

it('reloads a mandatory update unless disabled', async () => {
  mockServer({ update: { ...update, mandatory: true } });
  await checkForUpdate('https://api/check');
  expect(mockOta.reloadApp).toHaveBeenCalledTimes(1);

  mockServer({ update: { ...update, mandatory: true } });
  await checkForUpdate('https://api/check', { reloadIfMandatory: false });
  expect(mockOta.reloadApp).toHaveBeenCalledTimes(1);
});

it('removes the progress listener even when the download fails', async () => {
  const remove = jest.fn();
  mockOta.onProgress.mockReturnValue({ remove });
  mockOta.downloadBundle.mockRejectedValue(new Error('CHECKSUM_MISMATCH'));
  mockServer({ update });

  await expect(
    checkForUpdate('https://api/check', { onProgress: jest.fn() })
  ).rejects.toThrow('CHECKSUM_MISMATCH');
  expect(remove).toHaveBeenCalled();
});

it('throws on server errors', async () => {
  mockServer({}, 500);

  await expect(checkForUpdate('https://api/check')).rejects.toThrow('HTTP 500');
});
