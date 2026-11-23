'use strict';
// Old apps read NSNumber.doubleValue. Never round a usable balance to zero,
// since that UI value is also used by shipped clients as a send-button gate.
function remainingPct(used,cap){
 if(!Number.isFinite(used)||!Number.isFinite(cap)||cap<=0||used<0||used>=cap)return 0;
 return Math.max(0.000001,Number(Math.min(100,(cap-used)/cap*100).toFixed(6)));
}
module.exports={remainingPct};
