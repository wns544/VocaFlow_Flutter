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
  await seed(path,{schema:num(1),id:str('book'),name:str('기존 단어장'),wordOrder:{arrayValue:{values:[num(42)]}},nextChange:num(0),migrationSourceRevision:num(34),migrationSourceUpdateTime:str('migration-proof')});
  await seed(`${path}/cards/42`,{id:num(42),term:str('つくづく'),reading:str('つくづく'),meaning:str('절실히')});
  const writes = [patch(path,{nextChange:num(1)}),patch(`${path}/cards/42`,{meaning:str('뼈저리게'),lastOperationId:str('op-1')}),{update:doc(`${path}/changes/000000000001`,{number:num(1),wordId:num(42),operationId:str('op-1')})},{update:doc(`${path}/operations/op-1`,{operationId:str('op-1')})}];
  let r=await commit(writes); assert.equal(r.status,200,JSON.stringify(r));
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
  console.log('PASS: migrated-card transaction, owner access, protected learning/migration fields, immutable history/operations, legacy blockade, independent progress writes');
})().catch(error => { console.error(error); process.exitCode=1; });
