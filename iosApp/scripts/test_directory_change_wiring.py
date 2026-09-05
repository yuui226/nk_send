"""Directory transaction/source guards. Interleaving and filesystem XCTest still require Mac."""
from pathlib import Path
import subprocess
import unittest
from directory_change_wiring import CHANGES, previous_directory_change_source

ROOT = Path(__file__).resolve().parents[2]
GRANT = 'iosApp/ZTransfer/Storage/ScopedDirectoryStore.swift'
QUEUE = 'iosApp/ZTransfer/Network/CameraOriginalQueue.swift'
CONTRACT = 'iosApp/ZTransfer/Storage/OriginalFilesReading.swift'
PROVIDER = 'iosApp/ZTransfer/Storage/ProviderOriginalStore.swift'
PROBE = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'

def read(path): return (ROOT/path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', 'fadbbcd:' + path], cwd=ROOT).decode('utf-8')
def between(value, start, end): return value.split(start, 1)[1].split(end, 1)[0]

class DirectoryChangeWiringTest(unittest.TestCase):
    def test_all_five_previous_sources_restore_exactly(self):
        self.assertEqual({GRANT, QUEUE, CONTRACT, PROVIDER, PROBE}, set(CHANGES))
        for path in CHANGES:
            self.assertEqual(before(path), previous_directory_change_source(path, read(path)))

    def test_preparation_is_non_publishing_and_provider_is_prebound(self):
        value = between(read(GRANT), '    func prepareSelection(', '    /// Compare-and-replace')
        for token in ('let previous = try withBookmarkLock', 'defer { access.stop(url) }',
                      'try validateCandidate(data)', 'owner: identity, previous: previous'):
            self.assertIn(token, value)
        for token in ('persist(', 'writeBookmarkLocked(', 'replaceBookmark(', 'createDirectory('):
            self.assertNotIn(token, value)
        self.assertIn('ProviderOriginalStore(directory: directory, selection: prepared.selection)', read(CONTRACT))
        self.assertIn('self.selection = selection', read(PROVIDER))

    def test_all_bookmark_mutation_paths_use_the_same_lock_and_compare_previous_bytes(self):
        value = read(GRANT)
        replace = between(value, '    private func replaceBookmark(', '    private func withBookmarkLock')
        self.assertIn('try withBookmarkLock {', replace)
        self.assertLess(replace.index('readBookmarkLocked() == expected'), replace.index('writeBookmarkLocked(data)'))
        self.assertIn('try withBookmarkLock { try writeBookmarkLocked(data) }', value)
        self.assertIn('try withBookmarkLock {', between(value, '    func forget()', '    private func persist'))
        self.assertIn('replaceBookmark(expected: selected.bookmark, with: access.bookmark(resolved.url))', value)
        bounded = between(value, '    private func readBookmarkLocked()', '    private func writeBookmarkLocked')
        self.assertIn('1_048_577 - data.count', bounded)
        self.assertIn('guard data.count <= 1_048_576', bounded)
        locked = between(value, '    private func withBookmarkLock', '    /// A malformed')
        self.assertIn('defer { Self.bookmarkLock.unlock() }', locked)
        self.assertNotIn('await ', locked)

    def test_committed_target_has_no_fallible_or_cancelled_post_commit_step(self):
        commit = between(read(GRANT), '    func commitSelection(', '    private func validateCandidate')
        self.assertIn('guard prepared.owner == identity', commit)
        self.assertTrue(commit.rstrip().endswith('try replaceBookmark(expected: prepared.previous, with: prepared.selection.bookmark)\n    }'))
        configure = between(read(QUEUE), 'func configureDestination(_ change:', '    @discardableResult\n    func enqueue')
        after = configure.split('try await change.commit()', 1)[1]
        # Remove the explanatory comment before checking executable statements.
        after = '\n'.join(line.split('//', 1)[0] for line in after.splitlines())
        for token in ('await ', 'try ', 'Task.checkCancellation'):
            self.assertNotIn(token, after)
        self.assertIn('destination = change.destination', after)
        self.assertIn('destinationRevision &+= 1', after)

    def test_only_execution_is_fenced_and_the_last_pause_or_stop_withdraws_start(self):
        value = read(QUEUE)
        self.assertIn('if changingDestination { startAfterDestinationChange = true; return }', value)
        self.assertIn('if shouldStart { start() }', value)
        self.assertIn('func pauseAfterCurrent() { startAfterDestinationChange = false;', value)
        self.assertIn('startAfterDestinationChange = false', between(value, '    func stop()', '    func snapshot()'))
        admissions = between(value, '    func enqueue(', '    func start()')
        previous_admissions = between(before(QUEUE), '    func enqueue(', '    func start()')
        self.assertEqual(previous_admissions, admissions)

    def test_late_optional_configuration_cannot_replace_a_newer_commit(self):
        value = between(read(QUEUE), 'func configureDestination(_ value:', '    /// Fence only execution')
        self.assertLess(value.index('let revision = destinationRevision'), value.index('await value.validateSelection()'))
        self.assertLess(value.index('revision == destinationRevision'), value.index('destination = value'))
        self.assertEqual(2, value.count('!changingDestination'))

    def test_ui_changes_owner_and_closes_old_page_only_after_queue_commit(self):
        value = between(read(PROBE), '    func selectQueueDirectory(', '    private func providerStore()')
        commit = value.index('queue.configureDestination(change)')
        for token in ('providerOriginals = change.provider', 'transferDestination = change.provider', 'filesPage?.close()'):
            self.assertGreater(value.index(token), commit)
        self.assertIn('if let selection, !forget, transferDestination != nil', read(PROBE))
        self.assertIn('directoryTask?.cancel()', between(read(PROBE), '    func disconnect()', '    func canDownload'))

    def test_normalizer_does_not_hide_changed_safety_or_unchanged_worker(self):
        for path, old, new in ((GRANT, 'readBookmarkLocked() == expected', 'true'),
                               (QUEUE, 'revision == destinationRevision', 'true'),
                               (PROVIDER, 'self.selection = selection', 'self.selection = nil')):
            with self.assertRaises(AssertionError):
                previous_directory_change_source(path, read(path).replace(old, new))
        changed = read(QUEUE).replace('let target = destination //', 'let target: OriginalFilesDestination? = nil //')
        self.assertNotEqual(before(QUEUE), previous_directory_change_source(QUEUE, changed))
