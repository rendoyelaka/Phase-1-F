#!/usr/bin/env bash
# =============================================================================
# generate_batch.sh — Step 9: Batch APK generation
# Usage: ./generate_batch.sh <N>
# Generates N unique companion+Nova APK pairs
# Output: batch_output/001/, batch_output/002/, ...
# =============================================================================

set -euo pipefail

# ── Validate argument ─────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Usage: ./generate_batch.sh <N>"
    echo "Example: ./generate_batch.sh 10"
    exit 1
fi

N=$1
if ! [[ "$N" =~ ^[0-9]+$ ]] || [ "$N" -lt 1 ]; then
    echo "[ERROR] N must be a positive integer"
    exit 1
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BATCH_OUT="${REPO_ROOT}/batch_output"
GRADLE="${REPO_ROOT}/gradlew"

echo "============================================="
echo " Batch APK Generator — ${N} pair(s)"
echo " Repo: ${REPO_ROOT}"
echo " Output: ${BATCH_OUT}"
echo "============================================="

# ── Clean previous batch output ───────────────────────────────────────────────
rm -rf "${BATCH_OUT}"
mkdir -p "${BATCH_OUT}"

# ── Integrity check log ───────────────────────────────────────────────────────
INTEGRITY_LOG="${BATCH_OUT}/integrity.log"
echo "BATCH_SIZE=${N}" > "${INTEGRITY_LOG}"
echo "GENERATED_AT=$(date '+%Y%m%d_%H%M%S')" >> "${INTEGRITY_LOG}"
echo "---" >> "${INTEGRITY_LOG}"

# ── Track hashes across pairs (for duplicate detection) ───────────────────────
declare -A SEEN_MD5
declare -A SEEN_SHA256

# ── Helper: compute MD5 ───────────────────────────────────────────────────────
apk_md5() {
    md5sum "$1" | awk '{print $1}'
}

# ── Helper: compute SHA-256 ───────────────────────────────────────────────────
apk_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

# ── Helper: zero-padded index ─────────────────────────────────────────────────
pad() {
    printf "%03d" "$1"
}

# ── Build loop ────────────────────────────────────────────────────────────────
FAILED=0
SUCCESS=0

for i in $(seq 1 "$N"); do
    IDX=$(pad "$i")
    PAIR_DIR="${BATCH_OUT}/${IDX}"
    mkdir -p "${PAIR_DIR}"

    echo ""
    echo "─────────────────────────────────────────────"
    echo " Building pair ${IDX} / $(pad $N)"
    echo "─────────────────────────────────────────────"

    # ── Clean Gradle build outputs (forces fresh keystore + fingerprint) ──────
    cd "${REPO_ROOT}"
    ./gradlew clean --quiet --no-daemon

    # ── Build Nova release APK (companion is processed inside build.yml in CI,
    #    but locally we build the Nova Gradle project which embeds companion) ──
    BUILD_LOG="${PAIR_DIR}/build.log"
    if ./gradlew assembleRelease --no-daemon 2>&1 | tee "${BUILD_LOG}"; then
        echo "✅ Pair ${IDX} — Gradle build succeeded"
    else
        echo "[ERROR] Pair ${IDX} — Gradle build FAILED. See ${BUILD_LOG}"
        echo "PAIR_${IDX}=FAILED" >> "${INTEGRITY_LOG}"
        FAILED=$((FAILED + 1))
        continue
    fi

    # ── Find output APK ───────────────────────────────────────────────────────
    APK_FILE=$(find "${REPO_ROOT}/app/build/outputs/apk/release" -name "*.apk" | head -1)
    if [ -z "$APK_FILE" ] || [ ! -f "$APK_FILE" ]; then
        echo "[ERROR] Pair ${IDX} — APK not found after build"
        echo "PAIR_${IDX}=NO_APK" >> "${INTEGRITY_LOG}"
        FAILED=$((FAILED + 1))
        continue
    fi

    # ── Copy APK to pair directory ────────────────────────────────────────────
    APK_NAME="nova_${IDX}_$(basename "$APK_FILE")"
    cp "$APK_FILE" "${PAIR_DIR}/${APK_NAME}"

    # ── Compute hashes ────────────────────────────────────────────────────────
    MD5=$(apk_md5 "${PAIR_DIR}/${APK_NAME}")
    SHA256=$(apk_sha256 "${PAIR_DIR}/${APK_NAME}")
    SIZE=$(du -h "${PAIR_DIR}/${APK_NAME}" | cut -f1)

    echo "   APK  : ${APK_NAME}"
    echo "   MD5  : ${MD5}"
    echo "   SHA256: ${SHA256}"
    echo "   Size : ${SIZE}"

    # ── Duplicate detection ───────────────────────────────────────────────────
    DUPE=0
    if [ -n "${SEEN_MD5[$MD5]+_}" ]; then
        echo "[WARNING] Pair ${IDX} — MD5 DUPLICATE of pair ${SEEN_MD5[$MD5]}"
        DUPE=1
    fi
    if [ -n "${SEEN_SHA256[$SHA256]+_}" ]; then
        echo "[WARNING] Pair ${IDX} — SHA256 DUPLICATE of pair ${SEEN_SHA256[$SHA256]}"
        DUPE=1
    fi

    SEEN_MD5[$MD5]="$IDX"
    SEEN_SHA256[$SHA256]="$IDX"

    # ── Copy fingerprint properties if available ──────────────────────────────
    FP_FILE=$(find "${REPO_ROOT}/app/build/fingerprint" -name "*.properties" 2>/dev/null | head -1)
    if [ -n "$FP_FILE" ] && [ -f "$FP_FILE" ]; then
        cp "$FP_FILE" "${PAIR_DIR}/fingerprint_${IDX}.properties"
    fi

    # ── Write pair integrity record ───────────────────────────────────────────
    {
        echo "PAIR_${IDX}_APK=${APK_NAME}"
        echo "PAIR_${IDX}_MD5=${MD5}"
        echo "PAIR_${IDX}_SHA256=${SHA256}"
        echo "PAIR_${IDX}_SIZE=${SIZE}"
        echo "PAIR_${IDX}_DUPE=${DUPE}"
        echo "PAIR_${IDX}_STATUS=OK"
    } >> "${INTEGRITY_LOG}"

    SUCCESS=$((SUCCESS + 1))
done

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo " Batch Complete"
echo " Success : ${SUCCESS} / ${N}"
echo " Failed  : ${FAILED} / ${N}"
echo " Log     : ${INTEGRITY_LOG}"
echo "============================================="

{
    echo "---"
    echo "TOTAL_SUCCESS=${SUCCESS}"
    echo "TOTAL_FAILED=${FAILED}"
} >> "${INTEGRITY_LOG}"

# ── Exit with error if any pair failed ───────────────────────────────────────
if [ "$FAILED" -gt 0 ]; then
    echo "[ERROR] ${FAILED} pair(s) failed. Check logs in ${BATCH_OUT}/"
    exit 1
fi

echo "✅ All ${N} pairs generated successfully"

# ── Step 11: Run batch integrity check ────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────"
echo " Running batch integrity check (Step 11)..."
echo "─────────────────────────────────────────────"
python3 "${SCRIPT_DIR}/batch_integrity_check.py" "${BATCH_OUT}"
exit 0
