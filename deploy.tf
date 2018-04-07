###############################################################################
#
# A simple K8s cluster in DO
#
###############################################################################


###############################################################################
#
# Get variables from command line or environment
#
###############################################################################


variable "do_token" {}
variable "do_region" {
    default = "nyc3"
}
variable "ssh_fingerprint" {}
variable "ssh_private_key" {
    default = "~/.ssh/id_rsa"
}

variable "number_of_workers" {}
variable "hyperkube_version" {
    default = "v1.8.4_coreos.0"
}

variable "prefix" {
    default = ""
}

variable "size_master" {
    default = "2gb"
}

variable "size_worker" {
    default = "2gb"
}


###############################################################################
#
# Specify provider
#
###############################################################################


provider "digitalocean" {
    token = "${var.do_token}"
}


###############################################################################
#
# Master host
#
###############################################################################


resource "digitalocean_droplet" "k8s_master" {
    image = "coreos-stable"
    name = "${var.prefix}k8s-master"
    region = "${var.do_region}"
    private_networking = true
    size = "${var.size_master}"
    ssh_keys = ["${split(",", var.ssh_fingerprint)}"]

    provisioner "file" {
        source = "./kube-flannel.yml"
        destination = "/tmp/kube-flannel.yml"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    provisioner "file" {
        source = "./00-master.sh"
        destination = "/tmp/00-master.sh"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    provisioner "file" {
        source = "./install-kubeadm.sh"
        destination = "/tmp/install-kubeadm.sh"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    # Install dependencies and set up cluster
    provisioner "remote-exec" {
        inline = [
            "chmod +x /tmp/install-kubeadm.sh",
            "sudo /tmp/install-kubeadm.sh",
            "export MASTER_PRIVATE_IP=\"${self.ipv4_address_private}\"",
            "export MASTER_PUBLIC_IP=\"${self.ipv4_address}\"",
            "chmod +x /tmp/00-master.sh",
            "sudo -E /tmp/00-master.sh"
        ]
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    # copy secrets to local
    provisioner "local-exec" {
        command =<<EOF
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.ssh_private_key} core@${digitalocean_droplet.k8s_master.ipv4_address}:"/tmp/kubeadm_join /etc/kubernetes/admin.conf" ${path.module}/secrets/
            sed -i "s/${self.ipv4_address_private}/${self.ipv4_address}/" ${path.module}/secrets/admin.conf
EOF
    }

}

###############################################################################
#
# Worker hosts
#
###############################################################################


resource "digitalocean_droplet" "k8s_worker" {
    count = "${var.number_of_workers}"
    image = "coreos-stable"
    name = "${var.prefix}${format("k8s-worker-%02d", count.index + 1)}"
    region = "${var.do_region}"
    size = "${var.size_worker}"
    private_networking = true
    # user_data = "${data.template_file.worker_yaml.rendered}"
    ssh_keys = ["${split(",", var.ssh_fingerprint)}"]
    depends_on = ["digitalocean_droplet.k8s_master"]

    # Start kubelet
    provisioner "file" {
        source = "./01-worker.sh"
        destination = "/tmp/01-worker.sh"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    provisioner "file" {
        source = "./install-kubeadm.sh"
        destination = "/tmp/install-kubeadm.sh"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    provisioner "file" {
        source = "./secrets/kubeadm_join"
        destination = "/tmp/kubeadm_join"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    # Install dependencies and join cluster
    provisioner "remote-exec" {
        inline = [
            "chmod +x /tmp/install-kubeadm.sh",
            "sudo /tmp/install-kubeadm.sh",
            "export NODE_PRIVATE_IP=\"${self.ipv4_address_private}\"",
            "chmod +x /tmp/01-worker.sh",
            "sudo -E /tmp/01-worker.sh"
        ]
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }
}

# use kubeconfig retrieved from master

resource "null_resource" "label_ingress_node" {
   depends_on = ["digitalocean_droplet.k8s_worker"]
   provisioner "local-exec" {
       command = <<EOF
           export KUBECONFIG=${path.module}/secrets/admin.conf
           until kubectl get nodes 2>/dev/null; do printf '.'; sleep 5; done
           kubectl label nodes ${var.prefix}k8s-worker-01 kubernetes.io/role=ingress

EOF
   }
}


resource "null_resource" "deploy_nginx_ingress" {
    depends_on = ["digitalocean_droplet.k8s_worker"]
    provisioner "local-exec" {
        command = <<EOF
            export KUBECONFIG=${path.module}/secrets/admin.conf
            until kubectl get pods 2>/dev/null; do printf '.'; sleep 5; done
            kubectl create -f ${path.module}/04-ingress-controller.yaml
EOF
   }
}

resource "null_resource" "deploy_heapster" {
    depends_on = ["digitalocean_droplet.k8s_worker"]
    provisioner "local-exec" {
        command = <<EOF
            export KUBECONFIG=${path.module}/secrets/admin.conf
            until kubectl get pods 2>/dev/null; do printf '.'; sleep 5; done
            kubectl create -f ${path.module}/07-heapster.yaml
EOF
   }
}
resource "null_resource" "deploy_digitalocean_cloud_controller_manager" {
    depends_on = ["digitalocean_droplet.k8s_worker"]
    provisioner "local-exec" {
        command = <<EOF
            export KUBECONFIG=${path.module}/secrets/admin.conf
            sed -e "s/\$DO_ACCESS_TOKEN/${var.do_token}/" < ${path.module}/03-do-secret.yaml > ./secrets/03-do-secret.rendered.yaml
            until kubectl get pods 2>/dev/null; do printf '.'; sleep 5; done
            kubectl create -f ./secrets/03-do-secret.rendered.yaml
            kubectl create -f https://raw.githubusercontent.com/digitalocean/digitalocean-cloud-controller-manager/master/releases/v0.1.4.yml
EOF
    }
}

###############################################################################
#
# SSH Proxy host
#
###############################################################################

resource "digitalocean_droplet" "ssh_proxy" {
    image = "coreos-stable"
    name = "${var.prefix}ssh-proxy"
    region = "${var.do_region}"
    private_networking = true
    size = "s-1vcpu-1gb"
    ssh_keys = ["${split(",", var.ssh_fingerprint)}"]

    # Add sshguard
    provisioner "remote-exec" {
        inline = [
          "git clone https://github.com/pablocouto/coreos-sshguard.git",
          "sudo install -o root -m 644 coreos-sshguard/sshguard.service /etc/systemd/system/",
          "sudo systemctl enable sshguard",
          "sudo systemctl start sshguard",
        ]
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }
}

#outputs
output "worker_addresses" {
  value = ["${digitalocean_droplet.k8s_worker.*.ipv4_address_private}"]
}
output "master_address" {
  value = "${digitalocean_droplet.k8s_master.ipv4_address_private}"
}
output "ssh_address_public" {
  value = "${digitalocean_droplet.ssh_proxy.ipv4_address}"
}
output "ingress_address_public" {
  value = "${digitalocean_droplet.k8s_worker.0.ipv4_address}"
}
