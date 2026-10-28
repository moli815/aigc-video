const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../cloudfunctions/bf-image/index.js'),'utf8');
const snippet=source.slice(source.indexOf('const TIER_ALIASES'),source.indexOf('\nlet _rtLoadedAt'));
function route(mode,args){const context={autoDecision:require('../cloudfunctions/bf-image/image-routing').autoDecision,RT:{IMAGE_ROUTING_MODE:mode},modelsOf:()=>({fast:'flash',pro:'pro',series:''}),capsOf:()=>({layers:true,series:false})};vm.createContext(context);vm.runInContext(snippet,context);return context.selectImageRoute(args);}
test('auto defaults to Flash and treats legacy frontend high as a recommendation',()=>{
 assert.equal(route('auto',{taskKind:'generate',qualityTier:'fast'}).model,'flash');
 assert.equal(route('auto',{taskKind:'generate',qualityTier:'high'}).model,'flash');
 assert.equal(route('auto',{taskKind:'edit',qualityTier:'auto'}).model,'flash');
 assert.equal(route('auto',{taskKind:'reference',qualityTier:'nonsense'}).model,'flash');
});
test('operational pro_only prevents premature Flash traffic during tuning',()=>{
 assert.equal(route('pro_only',{taskKind:'generate',qualityTier:'fast'}).model,'pro');
 assert.equal(route('pro_only',{taskKind:'edit',qualityTier:'high'}).model,'pro');
});
test('auto does not invent an unsupported native series route',()=>{
 assert.equal(route('auto',{taskKind:'series',qualityTier:'high'}).unsupported,true);
});
