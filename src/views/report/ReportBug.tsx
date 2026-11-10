import { useState } from "react";
import { getBackend } from "@/ipc/client";
import { FORK_REPORT } from "@/lib/forkLinks";
import { startWindowDrag } from "@/lib/windowDrag";
import { useShowWindowWhenReady } from "@/lib/windowReady";
import styles from "./ReportBug.module.css";

export function ReportBug({ onClose, windowed = false }: { onClose: () => void; windowed?: boolean }) {
  const [error, setError] = useState("");
  const body = (
    <section className={styles.dialog} role="dialog" aria-label="Report bug" aria-modal={windowed ? undefined : true}>
      <header className={styles.title} onMouseDown={windowed ? startWindowDrag : undefined}>
        Report bug
        {windowed ? null : <button type="button" aria-label="Close report" onClick={onClose}>×</button>}
      </header>
      <div className={styles.form}>
        <div className={styles.fields}>
          <p>Report issues with this custom version to computergabe/rbxport on GitHub.</p>
          <p>Describe what happened and include your app version. You can review your report before submitting it on GitHub.</p>
          <p className={styles.hint}>GitHub issues are public. No logs, music paths, or personal information are attached automatically.</p>
          {error ? <p className={styles.error} role="alert">{error}</p> : null}
        </div>
        <footer>
          <button type="button" onClick={onClose}>Close</button>
          <button type="button" className={styles.save} onClick={() => {
            setError("");
            void getBackend().then(backend => backend.openUrl(FORK_REPORT))
              .catch(() => setError("Could not open your browser. Visit https://github.com/computergabe/rbxport/issues."));
          }}>Open GitHub issue</button>
        </footer>
      </div>
    </section>
  );
  return windowed ? body : <div className={styles.backdrop}>{body}</div>;
}

export function ReportWindow() {
  useShowWindowWhenReady();
  return <ReportBug windowed onClose={() => { void getBackend().then(backend => backend.closeWindow()); }} />;
}
