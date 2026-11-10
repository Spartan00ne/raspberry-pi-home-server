const API_URL = "/api/status";


function formatBytes(bytes) {

    if (bytes === 0) {
        return "0 B";
    }

    const units = [
        "B",
        "KB",
        "MB",
        "GB",
        "TB"
    ];

    const index =
        Math.floor(
            Math.log(bytes) /
            Math.log(1024)
        );

    return (
        bytes /
        Math.pow(1024, index)
    ).toFixed(1)
    + " "
    + units[index];
}


function formatUptime(seconds) {

    const days =
        Math.floor(seconds / 86400);

    seconds %= 86400;

    const hours =
        Math.floor(seconds / 3600);

    seconds %= 3600;

    const minutes =
        Math.floor(seconds / 60);


    if (days > 0) {
        return `${days}d ${hours}h ${minutes}m`;
    }

    if (hours > 0) {
        return `${hours}h ${minutes}m`;
    }

    return `${minutes}m`;
}


function setProgress(id, value) {

    const element =
        document.getElementById(id);

    element.style.width =
        `${Math.min(value, 100)}%`;
}


function setContainerStatus(
    elementId,
    status
) {

    const element =
        document.getElementById(elementId);

    if (status === "running") {

        element.classList.add("online");

        element.textContent = "";

    } else {

        element.classList.remove("online");

        element.textContent = "?";
    }
}


async function updateDashboard() {

    try {

        const response =
            await fetch(
                API_URL,
                {
                    cache: "no-store"
                }
            );


        if (!response.ok) {
            throw new Error(
                "API error"
            );
        }


        const data =
            await response.json();


        /* CPU */

        const cpu =
            data.system.cpu_percent;

        document.getElementById(
            "cpu"
        ).textContent =
            cpu.toFixed(1);

        setProgress(
            "cpu-bar",
            cpu
        );


        /* RAM */

        const ram =
            data.system.memory_percent;

        document.getElementById(
            "ram"
        ).textContent =
            ram.toFixed(1);

        setProgress(
            "ram-bar",
            ram
        );


        document.getElementById(
            "ram-detail"
        ).textContent =
            `${formatBytes(
                data.system.memory_used
            )} von ${formatBytes(
                data.system.memory_total
            )}`;


        /* Temperatur */

        document.getElementById(
            "temperature"
        ).textContent =
            data.system.temperature ??
            "--";


        /* Uptime */

        document.getElementById(
            "uptime"
        ).textContent =
            formatUptime(
                data.system.uptime
            );


        /* Root */

        const root =
            data.disk.root;

        if (root) {

            document.getElementById(
                "root-percent"
            ).textContent =
                `${root.percent}%`;

            setProgress(
                "root-bar",
                root.percent
            );

            document.getElementById(
                "root-detail"
            ).textContent =
                `${formatBytes(
                    root.used
                )} von ${formatBytes(
                    root.total
                )}`;
        }


        /* External drive */

        const externalDrive =
            data.disk.external_drive;

        if (externalDrive) {

            document.getElementById(
                "external-drive-percent"
            ).textContent =
                `${externalDrive.percent}%`;

            setProgress(
                "external-drive-bar",
                externalDrive.percent
            );

            document.getElementById(
                "external-drive-detail"
            ).textContent =
                `${formatBytes(
                    externalDrive.used
                )} von ${formatBytes(
                    externalDrive.total
                )}`;
        }


        /* Docker */

        setContainerStatus(
            "nginx-status",
            data.docker[
                "nginx-homepage"
            ]
        );


        setContainerStatus(
            "cloudflare-status",
            data.docker[
                "cloudflared"
            ]
        );


        /* Timestamp */

        const date =
            new Date(
                data.timestamp
            );

        document.getElementById(
            "updated"
        ).textContent =
            date.toLocaleTimeString(
                "de-DE"
            );


    } catch (error) {

        console.error(
            "Dashboard error:",
            error
        );

        document.getElementById(
            "updated"
        ).textContent =
            "API nicht erreichbar";
    }
}


updateDashboard();


setInterval(
    updateDashboard,
    5000
);
