"use strict";
// Seedream 5.5 计费口径：必须按上游真实用量算，不能按请求参数猜。
// 这三条锁住的是"用户会不会被多扣 / 平台会不会被白嫖"。
const fs=require("fs"),vm=require("vm"),assert=require("assert"),path=require("path"),test=require("node:test");

const SOURCE=fs.readFileSync(path.join(__dirname,"../cloudfunctions/bf-image/index.js"),"utf8");
const START=SOURCE.indexOf("function upstreamCostOf");
const END=SOURCE.indexOf("function priceForSize");
if(START<0||END<0||END<=START)throw new Error("PRICING_BLOCK_NOT_FOUND");
const BLOCK=SOURCE.slice(START,END);

function build(){
 const ctx={
  reqStore:{getStore:()=>null},
  RT:{
   IMAGE_COST_PRO_SMALL:"0.3",IMAGE_COST_PRO_LARGE:"0.6",
   IMAGE_COST_PRO_LAYER_SMALL:"0.15",IMAGE_COST_PRO_LAYER_LARGE:"0.3",
   IMAGE_COST_FLASH:"0.12",IMAGE_COST_LITE:"0.22",IMAGE_COST_45:"0.25",IMAGE_COST_40:"0.2",
   IMAGE_COST_EXTRA_INPUT:"0.02",
   IMAGE_COST_55_INPUT:"0.05",IMAGE_COST_55_OUT_SMALL:"0.13",IMAGE_COST_55_OUT_LARGE:"0.23",
   IMAGE_PRICE_MULTIPLIER:"2",IMAGE_SIZE:"1.5K",
  },
 };
 vm.createContext(ctx);
 vm.runInContext(BLOCK+";this.cost=actualUpstreamCostOf;this.base=upstreamCostOf;this.price=customerPriceOf;",ctx);
 return ctx;
}
const c=build();

test("5.5 海报：2 张输入 + 1 张 420 万像素 = 0.33 元",()=>{
 const cost=c.cost({model:"doubao-seedream-5-5-261028",size:"2K",
  usage:{input_images:2,generated_images:1,output_sizes:["1776x2368"]}});
 assert.equal(cost,0.33);
 assert.equal(c.price(cost),0.66);
});

test("5.5 拆层：1 张输入 + 17 张 130 万像素 = 2.26 元（不能只算 1 张）",()=>{
 const sizes=Array(17).fill("1024x1278");
 const cost=c.cost({model:"doubao-seedream-5-5-261028",size:"1K",
  usage:{input_images:1,generated_images:17,output_sizes:sizes}});
 assert.equal(cost,2.26);
 // 只按 1 张算会得到 0.18，正是过去少扣的地方
 const oneShot=c.cost({model:"doubao-seedream-5-5-261028",size:"1K",
  usage:{input_images:1,generated_images:1,output_sizes:["1024x1278"]}});
 assert.equal(oneShot,0.18);
});

test("5.5 混档：大图层按 0.23、小图层按 0.13 各自落档",()=>{
 const cost=c.cost({model:"doubao-seedream-5-5-261028",size:"2K",
  usage:{input_images:0,generated_images:2,output_sizes:["1776x2368","800x600"]}});
 assert.equal(cost,0.36);
});

test("5.5 缺用量时按实际张数回落，不默认 1 张",()=>{
 const cost=c.cost({model:"doubao-seedream-5-5-261028",size:"2K",
  usage:{input_images:1,generated_images:3,output_sizes:[]}});
 assert.equal(cost,Number((0.05+3*0.23).toFixed(4)));
});

test("5.5 输入图必须计费：多一张输入就多 0.05",()=>{
 const a=c.cost({model:"doubao-seedream-5-5-261028",size:"2K",usage:{input_images:0,generated_images:1,output_sizes:["1776x2368"]}});
 const b=c.cost({model:"doubao-seedream-5-5-261028",size:"2K",usage:{input_images:2,generated_images:1,output_sizes:["1776x2368"]}});
 assert.equal(Number((b-a).toFixed(4)),0.1);
});

test("5.0 Pro 口径不受 5.5 影响：2K 仍 0.60、1.5K 仍 0.30",()=>{
 assert.equal(c.cost({model:"doubao-seedream-5-0-pro-260628",size:"2K",usage:null}),0.6);
 assert.equal(c.cost({model:"doubao-seedream-5-0-pro-260628",size:"1.5K",usage:null}),0.3);
 assert.equal(c.cost({model:"doubao-seedream-5-0-pro-260628",size:"2K",inputImages:3,usage:null}),0.64);
});

test("未知模型不会因为 5.5 分支而漏成 0，按 Pro 小图保守计",()=>{
 const cost=c.cost({model:"some-unknown-model",size:"2K",usage:{input_images:1,generated_images:1,output_sizes:["1776x2368"]}});
 assert.equal(cost,0.3);
 assert.ok(cost>0,"未知模型绝不能算出 0，否则就是白嫖");
});
