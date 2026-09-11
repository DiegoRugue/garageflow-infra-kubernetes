output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_security_group_id" {
  description = "Primary security group ID created for the EKS cluster."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group_name" {
  description = "Managed worker node-group name."
  value       = aws_eks_node_group.this.node_group_name
}

output "node_instance_types" {
  description = "EC2 types used by managed workers."
  value       = aws_eks_node_group.this.instance_types
}

output "node_desired_size" {
  description = "Desired number of managed worker nodes."
  value       = aws_eks_node_group.this.scaling_config[0].desired_size
}
