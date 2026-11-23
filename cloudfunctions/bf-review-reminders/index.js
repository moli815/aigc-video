"use strict";
const tcb=require('@cloudbase/node-sdk');
const {sweep}=require('./shared/review-reminders');
exports.main=async()=>{try{return await sweep({db:tcb.init({env:process.env.TCB_ENV}).database()});}catch{return{state:'storage_unavailable'};}};
