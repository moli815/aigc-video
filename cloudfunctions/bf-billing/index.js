"use strict";
const tcb = require("@cloudbase/node-sdk");
const { collect } = require("./collector");
exports.main = async () => {
  const db = tcb.init({ env: process.env.TCB_ENV }).database();
  // Return only non-secret import status. No client-accessible HTTP route is created.
  return collect({ db, log: event => console.log(JSON.stringify(event)) });
};
