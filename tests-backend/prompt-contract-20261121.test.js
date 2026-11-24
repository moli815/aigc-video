"use strict";
// Verify the shipped bakery scenario against the current delivery modules.
const test = require("node:test");
const assert = require("node:assert/strict");
const poster = require("../cloudfunctions/shared/poster-delivery");
const intent = require("../cloudfunctions/bf-api/intent-contract");
const PRODUCTS = [
  ["栗子奶油欧包", "北海道小麦粉 · 栗子泥 40 克", "¥18"],
  ["栗香麻薯", "一盒六个 · 冷藏更好吃", "¥12"],
  ["焦糖栗子塔", "手工挞皮 · 流心", "¥22"],
  ["栗子拿铁", "现磨咖啡 · 栗子糖浆", "¥26"],
  ["栗子巴斯克", "低糖 · 六寸整模", "¥28"],
  ["栗子可颂", "32 层黄油起酥", "¥16"],
];

function blockList() {
  const items = [
    { role: "title", text: "栗香上市" },
    { role: "subtitle", text: "燕山板栗 · 慢火熬煮 4 小时 · 每日现烤" },
  ];
  for (const [n, d, p] of PRODUCTS) {
    items.push({ role: "label", text: n }, { role: "body", text: d }, { role: "body", text: p });
  }
  items.push({ role: "contact", text: "全国服务热线 400-826-7718" });
  items.push({ role: "footer", text: "麦禾堂 MAIHE BAKERY · 苏州 12 家门店" });
  return items;
}

test("旧包的四种文案格式可进入当前海报链路", () => {
  const fields={title:"栗香上市",contact:"400-826-7718"};
  for(const structured of [{text:blockList()},{text:"栗香上市\n400-826-7718"},{text:fields},fields]){
    const rows=poster.copyOf(structured);
    assert.ok(rows.some(row=>row.text.includes("栗香上市")));
    assert.ok(rows.some(row=>row.text.includes("400-826-7718")));
  }
});
test("六种产品的名称、说明和价格按原顺序完整印一次",()=>{
  const structured=poster.mark({text:blockList()},"做张暖色烘焙海报，表面要有栗子的质感");
  const prompt=poster.compile({visual:"店内木台上的点心",structured,density:"dense"});
  let last=-1;
  for(const item of blockList()){
    const literal=JSON.stringify(item.text);
    const index=prompt.indexOf(literal);
    assert.ok(index>last,item.text);assert.equal(prompt.indexOf(literal,index+literal.length),-1,item.text);last=index;
  }
});
test("长说明不因行数限制而截断",()=>{
  const long="面团先在四摄氏度冷库醒发十八小时，次日清晨五点进炉。".repeat(12);
  const structured={text:[...blockList(),{role:"body",text:long}]};
  assert.ok(poster.compile({visual:"烘焙柜台",structured,density:"dense"}).includes(JSON.stringify(long)));
});
test("普通摄影、插画和局部改图保留作者表达",()=>{
  for(const prompt of ["一只橘猫趴在窗台晒太阳，写实摄影","扁平风咖啡杯插画，莫兰迪色系","把背景换成海边"]){
    const call={function:{name:"image_generate",arguments:JSON.stringify({prompt})}};
    const [out]=intent.apply([call],intent.resolve({messages:[{role:"user",content:prompt}]}));
    const args=JSON.parse(out.function.arguments);assert.equal(args.prompt,prompt);assert.equal(args.structured?.poster_delivery,undefined);
  }
});
