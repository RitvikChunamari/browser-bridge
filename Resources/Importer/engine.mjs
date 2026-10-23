export const journalKey = id => `zenbridge:${id}`;
const safeURL = url => { try { return ['http:', 'https:'].includes(new URL(url).protocol); } catch { return false; } };
const save = (api, journal) => api.storage.local.set({[journalKey(journal.packageID)]: journal});
export async function getJournal(api, id) { return (await api.storage.local.get(journalKey(id)))[journalKey(id)]; }

export async function importPackage(api, payload, options, progress = () => {}) {
  if (payload.schema !== 1 || !payload.packageID || !payload.snapshot) throw Error('Unsupported migration package. Re-export with Browser Bridge.');
  const s = payload.snapshot;
  let j = await getJournal(api, payload.packageID) || {packageID: payload.packageID, state: 'new', bookmarkRoot: null, bookmarkDone: false, tabs: [], history: [], errors: [], skippedURLs: 0};
  if (j.state === 'rolled-back') j = {...j, state: 'new', bookmarkRoot: null, bookmarkDone: false, tabs: [], history: [], errors: []};
  j.state = 'running'; j.errors = []; await save(api, j);
  j.previousRoots ||= []; j.groups ||= {};
  const report = async text => { await save(api, j); progress(text); };
  try {
    if (options.bookmarks && !j.bookmarkDone) {
      // A user may have edited an incomplete tree. Preserve it on retry; only explicit rollback removes trees.
      if (j.bookmarkRoot) {
        j.previousRoots.push(j.bookmarkRoot); j.bookmarkRoot = null;
        j.errors.push('Preserved an incomplete bookmark tree from an earlier attempt. Review it or use explicit rollback.');
        await save(api, j);
      }
      // Initialize Firefox's fresh Places tree and explicitly choose an editable container in either family.
      const tree = await api.bookmarks.getTree();
      const containers = (tree[0]?.children || []).filter(node => !node.url && !node.unmodifiable);
      const parent = containers.find(node => node.id === 'unfiled_____' || node.id === '2' || node.folderType === 'other') || containers[0];
      if (!parent) throw Error('No editable bookmark folder is available. Open the browser’s bookmark manager, then retry.');
      const root = await api.bookmarks.create({parentId: parent.id, title: `Browser Bridge · ${payload.createdAt || payload.packageID}`});
      j.bookmarkRoot = root.id; await report('Preserving workspace and folder trees…');
      const addFolder = async (title, parentId) => (await api.bookmarks.create({title, parentId})).id;
      const addLink = async (title, url, parentId) => {
        if (!safeURL(url)) { j.skippedURLs++; return; }
        await api.bookmarks.create({title: title || url, url, parentId});
      };
      const spaces = new Map(), folders = new Map(), resolving = new Set();
      for (const space of s.spaces) spaces.set(space.id, await addFolder(space.name, root.id));
      const unknown = await addFolder('Unassigned tabs', root.id);
      const essentials = await addFolder('Essentials', root.id);
      async function ensureFolder(id) {
        if (folders.has(id)) return folders.get(id);
        const f = s.folders.find(f => f.id === id);
        if (!f || resolving.has(id)) return unknown;
        resolving.add(id);
        const parentId = f.parentID ? await ensureFolder(f.parentID) : spaces.get(f.spaceID) || unknown;
        const dest = await addFolder(f.name || 'Untitled folder', parentId);
        resolving.delete(id); folders.set(id, dest); return dest;
      }
      for (const f of s.folders) await ensureFolder(f.id);
      for (const t of s.tabs) await addLink(t.title, t.originalURL || t.url, t.essential ? essentials : t.folderID ? await ensureFolder(t.folderID) : spaces.get(t.spaceID) || unknown);
      const savedRoot = await addFolder('Saved bookmarks', root.id), savedFolders = new Map(), stack = new Set();
      async function ensureBookmark(id) {
        if (savedFolders.has(id)) return savedFolders.get(id);
        const b = s.bookmarks.find(b => b.id === id);
        if (!b || b.type !== 2 || stack.has(id)) return savedRoot;
        stack.add(id); const parentId = await ensureBookmark(b.parent);
        const result = await addFolder(b.title || 'Bookmarks', parentId);
        stack.delete(id); savedFolders.set(id, result); return result;
      }
      for (const b of s.bookmarks) {
        if (b.type === 2) await ensureBookmark(b.id);
        else if (b.url) await addLink(b.title, b.url, await ensureBookmark(b.parent));
      }
      j.bookmarkDone = true; await report('Bookmark tree imported.');
    }
    if (options.history) {
      const done = new Set(j.history.map(h => h.url));
      for (const h of s.history) {
        if (!safeURL(h.url) || done.has(h.url)) continue;
        const existing = await api.history.getVisits({url: h.url});
        if (existing.length) continue; // Never alter existing destination history.
        await api.history.addUrl({url: h.url}); // The browser API cannot set visit times; original times remain in snapshot.json.
        const inserted = await api.history.getVisits({url: h.url});
        j.history.push({url: h.url, visits: inserted.map(v => v.id)}); done.add(h.url);
        await report(`Imported ${j.history.length} history URLs…`);
      }
    }
    if (options.tabs) {
      const done = new Set(j.tabs.map(t => t.sourceID));
      const chosen = s.tabs.filter(t => options.space === '*' || (t.spaceID || '') === options.space || t.essential);
      let opened = 0;
      for (const t of chosen) {
        if (done.has(t.id)) continue;
        if (!safeURL(t.originalURL || t.url)) { j.skippedURLs++; continue; }
        if (opened >= (options.limit || 50)) break;
        const url = t.originalURL || t.url;
        const tab = await api.tabs.create({url, pinned: Boolean(t.pinned || t.essential), active: false});
        j.tabs.push({sourceID: t.id, id: tab.id, url, sessionID: options.sessionID}); done.add(t.id); opened++;
        await report(`Opened ${opened} tabs this run…`);
        if (t.folderID && !t.pinned && !t.essential && api.tabGroups && api.tabs.group) {
          try {
            const groupKey = `${options.sessionID}:${t.spaceID || ''}:${t.folderID}`;
            let groupId = j.groups[groupKey];
            if (groupId !== undefined) { try { await api.tabGroups.get(groupId); } catch { groupId = undefined; } }
            if (groupId === undefined) {
              groupId = await api.tabs.group({tabIds: [tab.id]}); j.groups[groupKey] = groupId;
              const parts = [], seen = new Set(); let id = t.folderID;
              while (id && !seen.has(id)) { seen.add(id); const f = s.folders.find(f => f.id === id); if (!f) break; parts.unshift(f.name); id = f.parentID; }
              const space = s.spaces.find(w => w.id === t.spaceID)?.name;
              await api.tabGroups.update(groupId, {title: [space, ...parts].filter(Boolean).join(' / '), collapsed: true});
            } else await api.tabs.group({tabIds: [tab.id], groupId});
            await save(api, j);
          } catch (error) { j.errors.push(`Tab retained, but group could not be created: ${error.message}`); }
        }
      }
      const remaining = chosen.filter(t => !done.has(t.id) && safeURL(t.originalURL || t.url)).length;
      j.remainingTabs = remaining;
    }
    j.state = j.errors.length ? 'completed-with-warnings' : 'complete';
    await report('Selected import finished.'); return j;
  } catch (error) {
    const failure = /parentGuid must be valid/i.test(error.message)
      ? new Error('The browser’s bookmark folders are not ready. Open its bookmark manager, wait for initialization, then retry. Partial import trees are preserved.') : error;
    j.state = 'interrupted'; j.errors.push(failure.message); await save(api, j); throw failure;
  }
}

export async function rollbackPackage(api, id, sessionID, progress = () => {}) {
  const j = await getJournal(api, id);
  if (!j) throw Error('No import journal exists for this package in this destination profile.');
  const retained = [], failures = [];
  for (const t of j.tabs) {
    // Tab IDs can be reused after restart. Only close our IDs in the same browser session and at their original URL.
    if (t.sessionID !== sessionID) { retained.push(t); continue; }
    let current;
    try { current = await api.tabs.get(t.id); }
    catch (error) {
      if (!/No tab with (?:id|the given id)|Invalid tab ID/i.test(error.message)) { retained.push(t); failures.push(`Could not inspect tab ${t.id}: ${error.message}`); }
      continue;
    }
    try {
      if ((current.pendingUrl || current.url) !== t.url) { retained.push(t); continue; }
      await api.tabs.remove(t.id);
    } catch (error) { retained.push(t); failures.push(`Could not close tab ${t.id}: ${error.message}`); }
  }
  const rootsLeft = [];
  for (const root of [...(j.previousRoots || []), ...(j.bookmarkRoot ? [j.bookmarkRoot] : [])]) {
    try { await api.bookmarks.get(root); await api.bookmarks.removeTree(root); }
    catch (error) { rootsLeft.push(root); failures.push(`Bookmark rollback needs review: ${error.message}`); }
  }
  j.bookmarkRoot = null; j.bookmarkDone = false; j.previousRoots = rootsLeft;
  // The browser API offers URL-wide deletion, not atomic deletion by visit ID. Keep history rather than race concurrent browsing.
  const historyLeft = j.history;
  if (historyLeft.length) failures.push('History URLs retained: The browser API cannot safely undo individual imported visits. Review the journal.');
  j.tabs = retained; j.history = historyLeft; j.errors = failures;
  j.state = retained.length || historyLeft.length || failures.length ? 'rollback-partial' : 'rolled-back';
  await save(api, j); progress(j.state); return j;
}
