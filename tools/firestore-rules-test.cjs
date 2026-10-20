const assert = require('node:assert/strict');
const project = 'demo-vocaflow-sync';
const uid = 'owner-user';
const base = `http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/${project}/databases/(default)/documents`;
const path = `users/${uid}/cardBooks/book`;
const now = Math.floor(Date.now() / 1000);
function token(user) {
  const enc = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${enc({alg:'none', typ:'JWT'})}.${enc({aud:project, iss:`https://securetoken.google.com/${project}`, sub:user, user_id:user, iat:now, exp:now+3600, auth_time:now, firebase:{sign_in_provider:'custom',identities:{}}})}.`;
}
const str = value => ({stringValue:value});
const num = value => ({integerValue:String(value)});
const doc = (p, fields) => ({name:`projects/${project}/databases/(default)/documents/${p}`,fields});
async function request(method, suffix, data, user='owner') {
  const response = await fetch(base + suffix, {method,headers:{Authorization:`Bearer ${user === 'owner' ? 'owner' : token(user)}`,'Content-Type':'application/json'},body:data ? JSON.stringify(data) : undefined});
  return {status:response.status, body:await response.json()};
}
async function seed(p, fields) { const r=await request('PATCH', `/${p}`, {fields}); assert.equal(r.status,200,JSON.stringify(r)); }
async function commit(writes, user=uid) { return request('POST', ':commit', {writes}, user); }
function patch(p, fields) { return {update:doc(p,fields),updateMask:{fieldPaths:Object.keys(fields)}}; }
(async () => {
  await seed(`users/${uid}/cardSync/meta`,{cutover:{booleanValue:true}});
  const newBook = `users/${uid}/cardBooks/new-book`;
  let created = await commit([
    {update:doc(newBook,{schema:num(1),id:str('new-book'),name:str('새 단어장'),wordOrder:{arrayValue:{values:[num(0)]}},nextChange:num(1),deleted:{booleanValue:false},lastOperationKind:str('bookCreate')})},
    {update:doc(`${newBook}/cards/0`,{schema:num(1),id:num(0),term:str('新規'),reading:str('しんき'),meaning:str('신규'),deleted:{booleanValue:false},lastOperationKind:str('cardCreate')})}
  ]);
  assert.equal(created.status,200,JSON.stringify(created));
  created=await commit([patch(`${newBook}/cards/0`,{deleted:{booleanValue:true},lastOperationKind:str('cardDelete')})]); assert.equal(created.status,200,JSON.stringify(created));
  created=await commit([patch(`${newBook}/cards/0`,{deleted:{booleanValue:false},lastOperationKind:str('cardPatch')})]); assert.equal(created.status,403,JSON.stringify(created));
  created=await commit([patch(newBook,{deleted:{booleanValue:true},lastOperationKind:str('bookDelete')})]); assert.equal(created.status,200,JSON.stringify(created));
  created=await commit([{update:doc(`${newBook}/cards/1`,{id:num(1),term:str('X'),reading:str('X'),meaning:str('X')})}]); assert.equal(created.status,403,JSON.stringify(created));
  created=await commit([patch(newBook,{deleted:{booleanValue:false},lastOperationKind:str('bookPatch')})]); assert.equal(created.status,403,JSON.stringify(created));
  created=await commit([patch(newBook,{deleted:{booleanValue:false},lastOperationKind:str('bookRestore')})]); assert.equal(created.status,200,JSON.stringify(created));
  created=await commit([patch(`${newBook}/cards/0`,{deleted:{booleanValue:false},lastOperationKind:str('cardRestore')})]); assert.equal(created.status,200,JSON.stringify(created));
  created=await commit([{update:doc(`${newBook}/cards/2`,{id:num(2),term:str('X'),reading:str('X'),meaning:str('X'),state:str('memorized')})}]); assert.equal(created.status,403,JSON.stringify(created));
  await seed(path,{schema:num(1),id:str('book'),name:str('기존 단어장'),wordOrder:{arrayValue:{values:[num(42)]}},nextChange:num(0),migrationSourceRevision:num(34),migrationSourceUpdateTime:str('migration-proof')});
  await seed(`${path}/cards/42`,{id:num(42),term:str('つくづく'),reading:str('つくづく'),meaning:str('절실히')});
  const writes = [patch(path,{nextChange:num(1)}),patch(`${path}/cards/42`,{meaning:str('뼈저리게'),lastOperationId:str('op-1')}),{update:doc(`${path}/changes/000000000001`,{number:num(1),wordId:num(42),operationId:str('op-1')})},{update:doc(`${path}/operations/op-1`,{operationId:str('op-1')})}];
  let r=await commit(writes); assert.equal(r.status,200,JSON.stringify(r));
  const signalPath = `users/${uid}/syncSignals/cardBookChanges`;
  r=await commit([patch(`${path}/cards/42`,{meaning:str('절실히, 뼈저리게')}),patch(signalPath,{operationId:str('atomic-op')})]);
  assert.equal(r.status,200,JSON.stringify(r));
  r=await commit([patch(`${path}/cards/42`,{state:str('memorized')}),patch(signalPath,{operationId:str('rejected-op')})]);
  assert.equal(r.status,403,JSON.stringify(r));
  r=await request('GET',`/${signalPath}`,null,uid); assert.equal(r.body.fields.operationId.stringValue,'atomic-op');
  r=await commit([patch(`${path}/cards/42`,{meaning:str('뼈저리게')})]); assert.equal(r.status,200,JSON.stringify(r));
  r=await request('GET',`/${path}/cards/42`,null,uid); assert.equal(r.body.fields.meaning.stringValue,'뼈저리게');
  for (const [label,writes,user] of [
    ['other account',[patch(`${path}/cards/42`,{meaning:str('bad')})],'intruder'],
    ['learning injection',[patch(`${path}/cards/42`,{state:str('memorized')})],uid],
    ['migration mutation',[patch(path,{migrationSourceRevision:num(99)})],uid],
    ['immutable history',[patch(`${path}/changes/000000000001`,{wordId:num(99)})],uid],
    ['immutable operation',[patch(`${path}/operations/op-1`,{operationId:str('op-2')})],uid],
    ['legacy whole book',[patch(`users/${uid}/managedBooks/book`,{content:str('stale')})],uid],
  ]) { r=await commit(writes,user); assert.equal(r.status,403,`${label}: ${JSON.stringify(r)}`); }
  r=await commit([patch(`users/${uid}/learningStateV2/device`,{revision:str('progress')})]); assert.equal(r.status,200,JSON.stringify(r));
  await seed(`users/${uid}/learningSync/meta`,{minimumProtocol:num(3)});
  r=await commit([{update:doc(`users/${uid}/learningStateV2/device`,{revision:str('stale-pc')})}]); assert.equal(r.status,403,JSON.stringify(r));
  r=await commit([{update:doc(`users/${uid}/learningStateV2/device`,{revision:str('modern-progress'),protocol:num(3)})}]); assert.equal(r.status,200,JSON.stringify(r));
  r=await commit([{update:doc(`users/${uid}/learningStateV2/device`,{revision:str('stale-replacement')})}]); assert.equal(r.status,403,JSON.stringify(r));
  r=await commit([patch(`users/${uid}/learningSync/meta`,{minimumProtocol:num(0)})]); assert.equal(r.status,403,JSON.stringify(r));
  r=await commit([{update:doc(`users/${uid}/learningStateV2/other`,{revision:str('intruder'),protocol:num(3)})}],'other-user'); assert.equal(r.status,403,JSON.stringify(r));
  console.log('PASS: old-client head publication denied after protocol cutover; modern head allowed; policy admin-only');
  console.log('PASS: migrated-card transaction, owner access, protected learning/migration fields, immutable history/operations, legacy blockade, independent progress writes');
  // Strict mode is staged independently of the legacy/cutover compatibility
  // checks above. These writes mirror the actual Dart transaction shapes.
  await seed(`users/${uid}/cardSync/meta`,{cutover:{booleanValue:true},requireAtomicOperations:{booleanValue:true}});
  const strict = `users/${uid}/cardBooks/strict`;
  await seed(strict,{schema:num(1),id:str('strict'),name:str('strict'),wordOrder:{arrayValue:{values:[num(42)]}},nextChange:num(0),migrationSourceRevision:num(34)});
  await seed(`${strict}/cards/42`,{id:num(42),term:str('語'),reading:str('ご'),meaning:str('원문'),fieldRevisions:{mapValue:{fields:{meaning:num(0)}}}});
  const map = fields => ({mapValue:{fields}});
  function atomic(kind, number, fields={}, before={}, {root=strict,wordId=42,create=false}={}) {
    const id=`strict-${kind}-${number}`, changeId=String(number).padStart(12,'0');
    const parent={nextChange:num(number),lastOperationId:str(id),lastOperationKind:str(kind)};
    let writes=[];
    if (kind.startsWith('card')) {
      const content={...fields,deleted:{booleanValue:kind==='cardDelete'},lastOperationId:str(id),lastOperationKind:str(kind)};
      if(Object.keys(fields).length) content.fieldRevisions=map(Object.fromEntries(Object.keys(fields).map(k=>[k,num(number)])));
      if(create) { content.id=num(wordId); writes.push({update:doc(`${root}/cards/${wordId}`,content)}); }
      else writes.push(patch(`${root}/cards/${wordId}`,content));
    } else Object.assign(parent,fields);
    const parentWrite=create && kind==='bookCreate'
      ? {update:doc(root,{schema:num(1),id:str(root.split('/').pop()),name:str('new'),wordOrder:{arrayValue:{values:[]}},...parent})}
      : patch(root,parent);
    writes.unshift(parentWrite);
    writes.push({update:doc(`${root}/changes/${changeId}`,{schema:num(1),number:num(number),kind:str(kind),wordId:num(wordId),fields:map(fields),before:map(before),operationId:str(id),deviceId:str('test-device'),localVersion:num(number)})});
    writes.push({update:doc(`${root}/operations/${id}`,{schema:num(1),operationId:str(id),changeNumber:num(number),changeId:str(changeId),wordId:num(wordId),kind:str(kind)})});
    for(const write of writes) write.updateTransforms=[{fieldPath:write.update.name.includes('/operations/') || write.update.name.includes('/changes/') ? 'createdAt':'updatedAt',setToServerValue:'REQUEST_TIME'}];
    return writes;
  }
  const valid=atomic('cardPatch',1,{meaning:str('새 뜻')},{meaning:str('원문')});
  for(const [label,writes] of [
    ['body only',[patch(`${strict}/cards/42`,{meaning:str('무기록')})]],
    ['parent only',[valid[0]]],
    ['receipt missing',valid.slice(0,-1)],
    ['history missing',valid.filter(w=>!w.update.name.includes('/changes/'))],
    ['history only',[valid[2]]], ['receipt only',[valid[3]]],
  ]) { r=await commit(writes); assert.equal(r.status,403,`${label}: ${JSON.stringify(r)}`); }
  const falsified=structuredClone(valid); falsified[1].update.fields.meaning=str('다른 본문');
  r=await commit(falsified); assert.equal(r.status,403,JSON.stringify(r));
  const wrongBefore=structuredClone(valid); wrongBefore[2].update.fields.before=map({meaning:str('틀린 이전값')});
  r=await commit(wrongBefore); assert.equal(r.status,403,JSON.stringify(r));
  const hiddenParent=structuredClone(valid); hiddenParent[0].update.fields.name=str('unrecorded rename'); hiddenParent[0].updateMask.fieldPaths.push('name');
  r=await commit(hiddenParent); assert.equal(r.status,403,'card patch cannot hide a book rename');
  const hiddenReading=structuredClone(valid); hiddenReading[1].update.fields.reading=str('unrecorded reading'); hiddenReading[1].updateMask.fieldPaths.push('reading');
  r=await commit(hiddenReading); assert.equal(r.status,403,'history must account for every changed text field');
  const jump=atomic('cardPatch',9,{meaning:str('점프')},{meaning:str('원문')});
  r=await commit(jump); assert.equal(r.status,403,JSON.stringify(r));
  r=await commit(valid); assert.equal(r.status,200,`strict patch: ${JSON.stringify(r)}`);
  r=await commit(valid); assert.equal(r.status,403,'old receipt cannot authorize a new write');
  r=await commit([patch(signalPath,{operationId:str('strict-cardPatch-1')})]); assert.equal(r.status,200,'idempotent replay may announce signal only');
  r=await commit(atomic('cardCreate',2,{term:str('新'),reading:str('しん'),meaning:str('신규')},{},{wordId:99,create:true})); assert.equal(r.status,200,`strict create: ${JSON.stringify(r)}`);
  r=await commit(atomic('cardDelete',3,{},{},{wordId:99})); assert.equal(r.status,200,`strict delete: ${JSON.stringify(r)}`);
  r=await commit(atomic('cardRestore',4,{},{},{wordId:99})); assert.equal(r.status,200,`strict restore: ${JSON.stringify(r)}`);
  r=await commit(atomic('bookDelete',5,{deleted:{booleanValue:true}})); assert.equal(r.status,200,JSON.stringify(r));
  r=await commit(atomic('bookRestore',6,{deleted:{booleanValue:false}})); assert.equal(r.status,200,JSON.stringify(r));
  r=await commit(atomic('bookPatch',7,{name:str('renamed')},{name:str('strict')})); assert.equal(r.status,200,JSON.stringify(r));
  r=await commit(atomic('bookCreate',1,{}, {},{root:`users/${uid}/cardBooks/strict-new`,create:true})); assert.equal(r.status,200,`strict book create: ${JSON.stringify(r)}`);
  r=await request('GET',`/${strict}`,null,uid); assert.equal(r.body.fields.migrationSourceRevision.integerValue,'34');
  console.log('PASS: staged atomic mode enforces new receipt/history/parent/card linkage, before/value consistency, no revision jumps or receipt reuse; all structural kinds remain writable');
})().catch(error => { console.error(error); process.exitCode=1; });
