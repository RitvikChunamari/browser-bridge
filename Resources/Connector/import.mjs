export const journalKey = id => `zenbridge:${id}`;
const safeURL = url => { try { return ['http:', 'https:'].includes(new URL(url).protocol); } catch { return false; } };
const save = (api, journal) => api.storage.local.set({[journalKey(journal.packageID)]: journal});
export async function getJournal(api, id) { return (await api.storage.local.get(journalKey(id)))[journalKey(id)]; }

export async function importPackage(api, payload, options, progress = () => {}) {
  if (payload.schema !== 1 || !payload.packageID || !payload.snapshot) throw Error('Unsupported migration package. Re-export with Browser Bridge.');
  const s = payload.snapshot;
  let j = await getJournal(api, payload.packageID) || {packageID: payload.packageID, state: 'new', bookmarkRoot: null, bookmarkDone: false, tabs: [], history: [], errors: [], skippedURLs: 0};
  if (j.state === 'rolled-back') j = {...j, state: 'new', bookmarkRoot: null, bookmarkDone: false, bookmarkNodes: {}, pendingTab: null, groups: {}, tabs: [], history: [], errors: []};
  j.state = 'running'; j.errors = []; await save(api, j);
  j.previousRoots ||= []; j.groups ||= {};
  const report = async text => { await save(api, j); progress(text); };
  try {
    if (options.bookmarks && !j.bookmarkDone) {
      // A retry reuses its own tree and stable source-node mappings. User edits are never overwritten;
      // independent verification will surface them before the app reports completion.
      const tree = await api.bookmarks.getTree();
      const containers = (tree[0]?.children || []).filter(node => !node.url && !node.unmodifiable);
      const parent = containers.find(node => node.id === 'unfiled_____' || node.id === '2' || node.folderType === 'other') || containers[0];
      if (!parent) throw Error('No editable bookmark folder is available. Open the browser’s bookmark manager, then retry.');
      if (!j.bookmarkRoot) {
        const title = `Browser Bridge · ${payload.createdAt || ''} · ${payload.packageID}`;
        const existing = (await api.bookmarks.getChildren(parent.id)).filter(node => !node.url && node.title === title);
        if (existing.length > 1) throw Error('Several matching import roots exist. Review them before retrying.');
        j.bookmarkRoot = existing[0]?.id || (await api.bookmarks.create({parentId: parent.id, title})).id;
        await report('Preserving workspace and folder trees…');
      } else await api.bookmarks.get(j.bookmarkRoot);
      const root = {id: j.bookmarkRoot};
      j.bookmarkNodes ||= {};
      const used = new Set(Object.values(j.bookmarkNodes));
      async function ensureNode(key, details) {
        if (j.bookmarkNodes[key]) {
          try { await api.bookmarks.get(j.bookmarkNodes[key]); return j.bookmarkNodes[key]; }
          catch { throw Error('A previously imported bookmark was removed. Review the partial tree before retrying.'); }
        }
        // Recover a create that reached the browser immediately before its journal checkpoint.
        const existing = (await api.bookmarks.getChildren(details.parentId)).find(node => !used.has(node.id) && node.title === details.title && (node.url || '') === (details.url || ''));
        const id = existing?.id || (await api.bookmarks.create(details)).id;
        used.add(id); j.bookmarkNodes[key] = id; await save(api, j); return id;
      }
      const addFolder = async (key, title, parentId) => ensureNode(key, {title, parentId});
      const addLink = async (key, title, url, parentId) => {
        if (!safeURL(url)) { j.skippedURLs++; return; }
        await ensureNode(key, {title: title || url, url, parentId});
      };
      const spaces = new Map(), folders = new Map(), resolving = new Set();
      for (const space of s.spaces) spaces.set(space.id, await addFolder(`space:${space.id}`, space.name, root.id));
      const unknown = await addFolder('unassigned', 'Unassigned tabs', root.id);
      const essentials = await addFolder('essentials', 'Essentials', root.id);
      async function ensureFolder(id) {
        if (folders.has(id)) return folders.get(id);
        const f = s.folders.find(f => f.id === id);
        if (!f || resolving.has(id)) return unknown;
        resolving.add(id);
        const parentId = f.parentID ? await ensureFolder(f.parentID) : spaces.get(f.spaceID) || unknown;
        const dest = await addFolder(`folder:${f.id}`, f.name || 'Untitled folder', parentId);
        resolving.delete(id); folders.set(id, dest); return dest;
      }
      for (const f of s.folders) await ensureFolder(f.id);
      for (const t of s.tabs) await addLink(`tab:${t.id}`, t.title, t.originalURL || t.url, t.essential ? essentials : t.folderID ? await ensureFolder(t.folderID) : spaces.get(t.spaceID) || unknown);
      const savedRoot = await addFolder('saved-root', 'Saved bookmarks', root.id), savedFolders = new Map(), stack = new Set();
      async function ensureBookmark(id) {
        if (savedFolders.has(id)) return savedFolders.get(id);
        const b = s.bookmarks.find(b => b.id === id);
        if (!b || b.type !== 2 || stack.has(id)) return savedRoot;
        stack.add(id); const parentId = await ensureBookmark(b.parent);
        const result = await addFolder(`bookmark-folder:${b.id}`, b.title || 'Bookmarks', parentId);
        stack.delete(id); savedFolders.set(id, result); return result;
      }
      for (const b of s.bookmarks) {
        if (b.type === 2) await ensureBookmark(b.id);
        else if (b.url) await addLink(`bookmark-link:${b.id}`, b.title, b.url, await ensureBookmark(b.parent));
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
      if (j.pendingTab) {
        const pending = j.pendingTab;
        if (pending.sessionID !== options.sessionID) throw Error('A tab was being created when the browser restarted. Review that tab before recovery; it will not be duplicated automatically.');
        const before = new Set(pending.before);
        const candidates = (await api.tabs.query({})).filter(tab => !before.has(tab.id) && (tab.pendingUrl || tab.url) === pending.url);
        if (candidates.length > 1) throw Error('Several tabs match an interrupted creation. Review them before retrying.');
        if (candidates.length === 1 && !done.has(pending.sourceID)) {
          j.tabs.push({sourceID: pending.sourceID, id: candidates[0].id, url: pending.url, sessionID: options.sessionID}); done.add(pending.sourceID);
        }
        delete j.pendingTab; await save(api, j);
      }
      let opened = 0;
      async function groupTab(t,tab) {
        if (options.groups !== false && t.folderID && !t.pinned && !t.essential && api.tabGroups && api.tabs.group) {
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
      for (const t of chosen) {
        if (done.has(t.id)) {
          const recorded=j.tabs.find(item=>item.sourceID===t.id);
          if(recorded?.sessionID===options.sessionID) {try{const tab=await api.tabs.get(recorded.id);if((tab.pendingUrl||tab.url)===recorded.url)await groupTab(t,tab);}catch(error){j.errors.push(`Imported tab needs review: ${error.message}`);}}
          continue;
        }
        if (!safeURL(t.originalURL || t.url)) { j.skippedURLs++; continue; }
        if (opened >= (options.limit || 50)) break;
        const url = t.originalURL || t.url;
        j.pendingTab = {sourceID: t.id, url, sessionID: options.sessionID, before: (await api.tabs.query({})).map(tab => tab.id)}; await save(api, j);
        const tab = await api.tabs.create({url, pinned: Boolean(t.pinned || t.essential), active: false});
        j.tabs.push({sourceID: t.id, id: tab.id, url, sessionID: options.sessionID}); delete j.pendingTab; done.add(t.id); opened++;
        await report(`Opened ${opened} tabs this run…`);
        await groupTab(t, tab);
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
  if(j.pendingTab)failures.push("An interrupted tab creation needs manual review; its uncertain tab is retained.");
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
