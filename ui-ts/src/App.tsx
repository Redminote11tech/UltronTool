import { BusProvider, useBus } from "./state/bus";
import { JobStatus } from "./components/JobStatus";
import { Rail } from "./components/Rail";
import { Toasts } from "./components/Toasts";
import { CloseGuard } from "./components/CloseGuard";
import { DevicePage } from "./pages/DevicePage";
import { FlashPage } from "./pages/FlashPage";
import { PartitionsPage } from "./pages/PartitionsPage";
import { ConsolePage } from "./pages/ConsolePage";

const PAGES = {
  device: { title: "Device connection", description: "Select a device and load its Firehose programmer." },
  flash: { title: "XML flash plans", description: "Batch flashing from rawprogram and patch XML files." },
  partitions: {title:"Partitions",description:"Save a backup or write an image to a selected partition. No XML required."},
  console: { title: "Session log", description: "Inspect backend messages and save a troubleshooting log." },
};
function Shell() {
  const { state } = useBus();
  const page = PAGES[state.page];
  const running = !!state.job && !state.job.finished;
  const status = state.daemonGone ? "Backend stopped" : running ? "Operation running" : state.source === "sim" ? "Simulation" : state.session === "firehose_ready" ? "Firehose connected" : state.session === "needs_loader" ? "Loader required" : "Waiting for connection";
  return <div className="app">
    <Rail />
    <main className="main">
      <header className="topbar"><div><h1>{page.title}</h1><p>{page.description}</p></div>
        <span className={`status-chip ${state.daemonGone ? "error" : ""}`}><span className="dot" />{status}</span>
      </header>
      <div className="content">
        <JobStatus/>
        {state.page === "device" && <DevicePage />}
        {state.page === "flash" && <FlashPage />}
        {state.page === "partitions" && <PartitionsPage />}
        {state.page === "console" && <ConsolePage />}
      </div>
    </main>
    <Toasts /><CloseGuard />
  </div>;
}
export default function App() { return <BusProvider><Shell /></BusProvider>; }
