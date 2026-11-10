"use strict";

const one = result => Array.isArray(result?.data) ? result.data[0] : result?.data;
const poolUsed = account => Number(account?.chatUsedCny || 0) + Number(account?.imageUsedCny || 0);
function addMonth(date, months) { const result = new Date(date); result.setMonth(result.getMonth() + months); return result; }

// Account/delivery/request/notification are one recoverable unit. A retry may
// safely regenerate credentials only when the legacy records do not already
// contain a password that matches the account hash.
async function fulfillApproval({
  db, request, staff, auto = false, now = new Date(), tiers, tierDefOf, memberMonths,
  periodKey, generated = {}, decryptPassword, verifyPassword,
}) {
  const reviewedBy = auto ? "system" : staff.sub;
  const notificationId = "ntf_" + request._id;
  return db.runTransaction(async tx => {
    const requestRef = tx.collection("bf_requests").doc(request._id);
    const notificationRef = tx.collection("bf_notifications").doc(notificationId);

    if (request.type === "renew") {
      const accountRef = tx.collection("bf_accounts").doc(request.accountId);
      const account = one(await accountRef.get());
      if (!account) throw new Error("ACCOUNT_NOT_FOUND");
      const applied = Array.isArray(account.renewedRequestIds) && account.renewedRequestIds.includes(request._id);
      let renewTo = account.expiresAt;
      if (!applied) {
        const from = account.expiresAt ? new Date(account.expiresAt) : now;
        const oldTier = tierDefOf(account);
        const newTier = tiers[request.tier] || oldTier;
        const upgrade = newTier.key !== oldTier.key;
        const base = upgrade ? now : (from.getTime() > now.getTime() ? from : now);
        renewTo = addMonth(base, memberMonths);
        let bonusDays = 0;
        if (upgrade) {
          const daily = newTier.poolCapCny / 30;
          if (Number.isFinite(daily) && daily > 0) {
            bonusDays = Math.max(0, Math.min(60, Math.floor(Math.max(0, oldTier.poolCapCny - poolUsed(account)) / daily)));
          }
          if (bonusDays) renewTo.setDate(renewTo.getDate() + bonusDays);
        }
        const patch = {
          expiresAt: renewTo, status: "active", cycleAnchorAt: now, periodKey: periodKey(),
          chatUsedCny: 0, imageUsedCny: 0, dayUsedCny: 0, weekUsedCny: 0,
          dayKey: null, weekKey: null, lastUpgradeBonusDays: bonusDays,
          renewedRequestIds: [...(account.renewedRequestIds || []), request._id],
        };
        if (tiers[request.tier]) {
          patch.tier = request.tier;
          patch.planPriceCny = tiers[request.tier].priceCny;
        }
        await accountRef.update(patch);
      }
      await requestRef.update({
        status: "approved", reviewedAt: now, reviewedBy, autoApproved: !!auto,
        renewFrom: account.expiresAt || now, renewTo, fulfillmentState: "done",
      });
      await notificationRef.set({
        toStaffId: request.submittedBy, type: "renew_ready", title: "续费已完成",
        body: `「${request.customerName}」的会员已续期至 ${new Date(renewTo).toISOString().slice(0, 10)}`,
        refRequestId: request._id, read: false, createdAt: now,
      });
      return { type: "renew", to: renewTo, idempotent: applied };
    }

    const accountId = "acct_" + request._id;
    const deliveryId = "dlv_" + request._id;
    const accountRef = tx.collection("bf_accounts").doc(accountId);
    const deliveryRef = tx.collection("bf_deliveries").doc(deliveryId);
    const account = one(await accountRef.get());
    const delivery = one(await deliveryRef.get());
    const username = account?.username || generated.username;
    let passwordCipher = delivery?.passwordCipher || generated.passwordCipher;
    let credentialsValid = false;
    if (account && delivery) {
      const plain = decryptPassword(delivery.passwordCipher);
      credentialsValid = !!plain && verifyPassword(plain, account.passwordHash);
    }

    if (!account) {
      const expiresAt = addMonth(now, memberMonths);
      await accountRef.set({
        _id: accountId, username, passwordHash: generated.passwordHash,
        displayName: request.customerName, realName: String(request.realName || "").slice(0, 20),
        phone: String(request.phone || "").slice(0, 11), status: "active",
        tier: tiers[request.tier] ? request.tier : "plus",
        planPriceCny: tiers[request.tier]?.priceCny ?? tiers.plus.priceCny,
        expiresAt, cycleAnchorAt: now, periodKey: periodKey(), chatUsedCny: 0, imageUsedCny: 0,
        createdAt: now, note: "",
      });
      passwordCipher = generated.passwordCipher;
    } else if (!credentialsValid) {
      // Legacy partial writes may have left a different random password in the
      // account and delivery. Reset both together instead of delivering a lie.
      await accountRef.update({ passwordHash: generated.passwordHash, pwv: Number(account.pwv || 0) + 1 });
      passwordCipher = generated.passwordCipher;
    }

    const deliveryBody = {
      chargedAt: request.createdAt, username, passwordCipher, issuedAt: now, note: "",
      realName: String(request.realName || "").slice(0, 20), phone: String(request.phone || "").slice(0, 11),
      staffId: request.submittedBy, staffName: request.submittedByName || "", reviewedBy,
      autoApproved: !!auto, requestId: request._id, accountId,
    };
    if (delivery) await deliveryRef.update(deliveryBody);
    else await deliveryRef.set({ _id: deliveryId, ...deliveryBody });

    await requestRef.update({
      status: "approved", reviewedAt: now, reviewedBy, autoApproved: !!auto,
      createdAccountUsername: username, deliveryId, fulfillmentState: "done",
    });
    await notificationRef.set({
      toStaffId: request.submittedBy, type: "account_ready", title: "你的会员账号已经准备好了",
      body: `「${request.customerName}」的会员账号已开通`, refRequestId: request._id,
      refDeliveryId: deliveryId, read: false, createdAt: now,
    });
    return { type: "create", username, idempotent: !!account && credentialsValid };
  });
}

module.exports = { fulfillApproval, addMonth, poolUsed };
